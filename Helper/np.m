#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdio.h>

typedef void (^InfoCB)(NSDictionary *);
typedef void (^BoolCB)(Boolean);
typedef void (^PidCB)(int);
static void (*GetInfo)(dispatch_queue_t, InfoCB);
static void (*GetPlaying)(dispatch_queue_t, BoolCB);
static void (*GetPid)(dispatch_queue_t, PidCB);
static void (*Register)(dispatch_queue_t);
static Boolean (*SendCmd)(int, id);

static BOOL load(void) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!h) return NO;
    GetInfo = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    GetPlaying = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    GetPid = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    Register = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    SendCmd = dlsym(h, "MRMediaRemoteSendCommand");
    return GetInfo && GetPlaying && GetPid;
}

static id clean(id v) {
    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]]) return v;
    if ([v isKindOfClass:[NSDate class]]) return @([(NSDate *)v timeIntervalSince1970]);
    return nil;
}

static void emit(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    GetInfo(q, ^(NSDictionary *info) {
        GetPlaying(q, ^(Boolean playing) {
            GetPid(q, ^(int pid) {
                NSMutableDictionary *o = [NSMutableDictionary dictionary];
                o[@"playing"] = @(playing);
                o[@"pid"] = @(pid);
                NSDictionary *map = @{
                    @"kMRMediaRemoteNowPlayingInfoTitle": @"title",
                    @"kMRMediaRemoteNowPlayingInfoArtist": @"artist",
                    @"kMRMediaRemoteNowPlayingInfoAlbum": @"album",
                    @"kMRMediaRemoteNowPlayingInfoDuration": @"duration",
                    @"kMRMediaRemoteNowPlayingInfoElapsedTime": @"elapsed",
                    @"kMRMediaRemoteNowPlayingInfoTimestamp": @"timestamp",
                    @"kMRMediaRemoteNowPlayingInfoPlaybackRate": @"rate" };
                for (NSString *k in map) { id v = clean(info[k]); if (v) o[map[k]] = v; }
                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([art isKindOfClass:[NSData class]] && art.length < 3000000)
                    o[@"art"] = [art base64EncodedStringWithOptions:0];
                o[@"hasInfo"] = @(info != nil);
                NSData *j = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
                if (j) { fwrite(j.bytes, 1, j.length, stdout); fputc('\n', stdout); fflush(stdout); }
            });
        });
    });
}

// Called from perl via DynaLoader xsub: args are ignored.
void np_stream(void *a, void *b) {
    @autoreleasepool {
        if (!load()) { fputs("{\"error\":\"load\"}\n", stdout); fflush(stdout); return; }
        // Exit when the parent (NotchDeck) goes away, so no orphaned helpers pile up.
        pid_t parent = getppid();
        dispatch_source_t ps = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)parent,
                                                      DISPATCH_PROC_EXIT, dispatch_get_main_queue());
        dispatch_source_set_event_handler(ps, ^{ exit(0); });
        dispatch_resume(ps);
        if (getppid() != parent || getppid() == 1) exit(0);
        static dispatch_source_t keep; keep = ps;
        if (Register) Register(dispatch_get_main_queue());
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        for (NSString *n in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                              @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
            [nc addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *x) { emit(); }];
        }
        emit();
        [[NSRunLoop mainRunLoop] run];
    }
}

// One-shot command: argument comes from env NP_CMD (0 play,1 pause,2 toggle,4 next,5 prev).
void np_command(void *a, void *b) {
    @autoreleasepool {
        if (!load() || !SendCmd) return;
        const char *c = getenv("NP_CMD");
        if (c) SendCmd(atoi(c), nil);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    }
}
