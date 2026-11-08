// A tiny bridge to the private MediaRemote framework (experimental "Now Playing from any app").
//
// Since macOS 15.4 MediaRemote answers only Apple-signed processes, so this library is loaded into /usr/bin/perl
// (see Sources/MediaRemoteSource.swift), which is allowed to use it. Two entry points, called as perl XSUBs:
//   adapter_stream() — runs until the pipe closes; prints one JSON line whenever the now-playing state changes
//   adapter_send()   — performs the command named by the MR_CMD environment variable, then returns
// Nothing here is linked into the app; if the framework or a symbol is missing the bridge just prints nothing.

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <dispatch/dispatch.h>
#include <CoreFoundation/CoreFoundation.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(CFTypeRef));
typedef CFStringRef (*ClientBundleFn)(CFTypeRef);
typedef Boolean (*SendCommandFn)(int, CFDictionaryRef);
typedef void (*SetElapsedFn)(double);

static void *framework(void) {
    static void *handle;
    if (!handle) handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    return handle;
}

static void *symbol(const char *name) {
    void *handle = framework();
    return handle ? dlsym(handle, name) : NULL;
}

// MARK: - JSON output

static void put_escaped(const char *s) {
    putchar('"');
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { putchar('\\'); putchar(c); }
        else if (c < 0x20) printf("\\u%04x", c);
        else putchar(c);
    }
    putchar('"');
}

static void put_string_field(const char *key, CFStringRef value) {
    char buffer[1024] = "";
    if (value && CFGetTypeID(value) == CFStringGetTypeID())
        CFStringGetCString(value, buffer, sizeof buffer, kCFStringEncodingUTF8);
    put_escaped(key); putchar(':'); put_escaped(buffer);
}

static void put_base64(const unsigned char *data, size_t length) {
    static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (size_t i = 0; i < length; i += 3) {
        unsigned v = data[i] << 16;
        if (i + 1 < length) v |= data[i + 1] << 8;
        if (i + 2 < length) v |= data[i + 2];
        putchar(table[(v >> 18) & 63]);
        putchar(table[(v >> 12) & 63]);
        putchar(i + 1 < length ? table[(v >> 6) & 63] : '=');
        putchar(i + 2 < length ? table[v & 63] : '=');
    }
}

static double number(CFDictionaryRef info, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(info, key);
    double result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberDoubleType, &result);
    return result;
}

// MARK: - Reading

static CFDictionaryRef fetch_info(void) {
    GetInfoFn get = symbol("MRMediaRemoteGetNowPlayingInfo");
    if (!get) return NULL;
    __block CFDictionaryRef copy = NULL;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    get(dispatch_get_global_queue(0, 0), ^(CFDictionaryRef info) {
        if (info) copy = CFDictionaryCreateCopy(NULL, info);
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    return copy;
}

static int fetch_playing(void) {
    GetPlayingFn get = symbol("MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    if (!get) return 0;
    __block int playing = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    get(dispatch_get_global_queue(0, 0), ^(Boolean value) {
        playing = value;
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    return playing;
}

static CFStringRef fetch_bundle(void) {
    GetClientFn get = symbol("MRMediaRemoteGetNowPlayingClient");
    ClientBundleFn bundle = symbol("MRNowPlayingClientGetBundleIdentifier");
    if (!get || !bundle) return NULL;
    __block CFStringRef identifier = NULL;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    get(dispatch_get_global_queue(0, 0), ^(CFTypeRef client) {
        CFStringRef value = client ? bundle(client) : NULL;
        if (value) identifier = CFStringCreateCopy(NULL, value);
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    return identifier;
}

void adapter_stream(void) {
    char last[2048] = "";
    double lastElapsed = -1000;
    double lastEmit = 0;
    for (;;) {
        CFDictionaryRef info = fetch_info();
        CFStringRef title = info ? CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoTitle")) : NULL;
        char signature[2048] = "";
        int playing = 0;
        double duration = 0, elapsed = 0;
        if (info && title) {
            playing = fetch_playing();
            duration = number(info, CFSTR("kMRMediaRemoteNowPlayingInfoDuration"));
            elapsed = number(info, CFSTR("kMRMediaRemoteNowPlayingInfoElapsedTime"));
            // The reported elapsed time is as of a timestamp; bring it up to date.
            CFDateRef stamp = CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoTimestamp"));
            if (playing && stamp && CFGetTypeID(stamp) == CFDateGetTypeID())
                elapsed += CFAbsoluteTimeGetCurrent() - CFDateGetAbsoluteTime(stamp);
            char t[512] = "", a[512] = "", al[512] = "";
            CFStringGetCString(title, t, sizeof t, kCFStringEncodingUTF8);
            CFStringRef artist = CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoArtist"));
            CFStringRef album = CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoAlbum"));
            if (artist) CFStringGetCString(artist, a, sizeof a, kCFStringEncodingUTF8);
            if (album) CFStringGetCString(album, al, sizeof al, kCFStringEncodingUTF8);
            snprintf(signature, sizeof signature, "%s|%s|%s|%.0f|%d", t, a, al, duration, playing);
        } else {
            snprintf(signature, sizeof signature, "none");
        }

        double now = CFAbsoluteTimeGetCurrent();
        int changed = strcmp(signature, last) != 0;
        // A seek moves the position far from where it should be.
        double expected = lastElapsed + (now - lastEmit);
        int seeked = !changed && playing && fabs(elapsed - expected) > 2.5;
        if (changed || seeked) {
            int newTrack = changed && (strncmp(signature, last, strchr(signature, '|') ? (size_t)(strchr(signature, '|') - signature) : 0) != 0 || last[0] == 0);
            if (!info || !title) {
                printf("{\"none\":true}\n");
            } else {
                printf("{");
                put_string_field("title", title); printf(",");
                put_string_field("artist", CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoArtist"))); printf(",");
                put_string_field("album", CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoAlbum"))); printf(",");
                printf("\"duration\":%.2f,\"elapsed\":%.2f,\"playing\":%s,", duration, elapsed, playing ? "true" : "false");
                CFStringRef bundle = fetch_bundle();
                put_string_field("bundle", bundle); 
                if (bundle) CFRelease(bundle);
                CFDataRef art = CFDictionaryGetValue(info, CFSTR("kMRMediaRemoteNowPlayingInfoArtworkData"));
                if (art && CFGetTypeID(art) == CFDataGetTypeID() && (newTrack || changed)) {
                    printf(",\"art\":\"");
                    put_base64(CFDataGetBytePtr(art), (size_t)CFDataGetLength(art));
                    printf("\"");
                }
                printf("}\n");
            }
            fflush(stdout);
            strncpy(last, signature, sizeof last - 1);
            lastElapsed = elapsed;
            lastEmit = now;
        }
        if (info) CFRelease(info);
        usleep(700 * 1000);
    }
}

// MARK: - Commands

void adapter_send(void) {
    const char *command = getenv("MR_CMD");
    if (!command) return;
    SendCommandFn send = symbol("MRMediaRemoteSendCommand");
    if (strncmp(command, "seek:", 5) == 0) {
        SetElapsedFn seek = symbol("MRMediaRemoteSetElapsedTime");
        if (seek) seek(atof(command + 5));
    } else if (send) {
        int code = -1;
        if (strcmp(command, "play") == 0) code = 0;
        else if (strcmp(command, "pause") == 0) code = 1;
        else if (strcmp(command, "toggle") == 0) code = 2;
        else if (strcmp(command, "next") == 0) code = 4;
        else if (strcmp(command, "previous") == 0) code = 5;
        if (code >= 0) send(code, NULL);
    }
    usleep(300 * 1000);
}
