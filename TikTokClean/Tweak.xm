#import <Foundation/Foundation.h>
#import <Photos/Photos.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <errno.h>
#import <stdio.h>

#if DEBUG || defined(TC_DIAGNOSTICS)
#define TCLog(format, ...) NSLog(@"[TikTokClean] " format, ##__VA_ARGS__)
#else
#define TCLog(format, ...) do { } while (0)
#endif

@interface UIViewController (TikTokCleanPrivate)
- (id)currentAweme;
- (id)currentCell;
- (void)scrollToNextVideo;
- (void)setPureMode:(BOOL)enabled;
@end

static UIView *gOverlay = nil;
static UIButton *gFullscreenButton = nil;
static UIButton *gDownloadButton = nil;
static UIButton *gAutoScrollButton = nil;
static UIViewController *gActiveFeedController = nil;
static NSObject *gOverlayTarget = nil;
static BOOL gPureMode = NO;
static BOOL gDownloadBusy = NO;
static BOOL gAutoScrollEnabled = YES;
static BOOL gProgressBarLogged = NO;

static NSString * const kTCHCLogFileName = @"log_tiktokclean.txt";

static id TCInvokeObject(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static void TCInvokeBool(id object, SEL selector, BOOL value) {
    if (!object || ![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
}

static void TCInvokeVoid(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL TCInvokeBoolReturn(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static long long TCInvokeIntegerReturn(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return 0;
    return ((long long (*)(id, SEL))objc_msgSend)(object, selector);
}

static void TCFinishDownload(BOOL success);
static void TCAutoScrollAdvance(void);
static void TCAttemptFeedSkip(NSString *reason);
static NSString *TCAwemeSkipReason(id aweme);
static BOOL TCAwemeIsAd(id aweme);
static BOOL TCHCWriteLine(NSString *line, NSDictionary **failureInfo);
static BOOL TCHCVersionAlreadyLogged(NSString *version);
static void TCRunHealthCheck(void);

static void TCHCEnsureDir(void) {
    NSString *dir = nil;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (paths.count > 0) {
        dir = paths.firstObject;
    }
    if (dir.length == 0) {
        paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count > 0) {
            dir = paths.firstObject;
        }
    }
    if (dir.length == 0) {
        dir = NSTemporaryDirectory();
    }
    if (dir.length > 0) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions: @(0755)}
                                                        error:NULL];
    }
}

static NSString *TCHCLogDirectory(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject;
    if (dir.length == 0) {
        paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        dir = paths.firstObject;
    }
    if (dir.length == 0) {
        dir = NSTemporaryDirectory();
    }
    return dir;
}

static NSString *TCHCLogPath(void) {
    return [TCHCLogDirectory() stringByAppendingPathComponent:kTCHCLogFileName];
}

#define TCHCLOG(fmt, ...) TCHCWriteLine([NSString stringWithFormat:(fmt), ##__VA_ARGS__], NULL)

static BOOL TCHCVersionAlreadyLogged(NSString *version) {
    if (version.length == 0) return NO;
    NSString *contents = [NSString stringWithContentsOfFile:TCHCLogPath() encoding:NSUTF8StringEncoding error:NULL];
    if (contents.length == 0) return NO;
    NSString *needle = [NSString stringWithFormat:@"TikTokClean health TikTok=%@", version];
    return [contents rangeOfString:needle].location != NSNotFound;
}

static BOOL TCHCWriteLine(NSString *line, NSDictionary **failureInfo) {
    if (!line) return NO;
    TCHCEnsureDir();

    static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
    NSString *path = TCHCLogPath();
    NSString *baseDir = [path stringByDeletingLastPathComponent];
    NSError *dirError = nil;
    BOOL createdDir = [[NSFileManager defaultManager] createDirectoryAtPath:baseDir
                                               withIntermediateDirectories:YES
                                                                attributes:@{NSFilePosixPermissions: @(0755)}
                                                                     error:&dirError];

    os_unfair_lock_lock(&sLock);

    @autoreleasepool {
        NSString *lineStr = [line stringByAppendingString:@"\n"];
        NSData *data = [lineStr dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) data = [NSData data];

        BOOL createdFile = [[NSFileManager defaultManager] createFileAtPath:path
                                                                   contents:nil
                                                                 attributes:@{NSFilePosixPermissions: @(0644)}];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        BOOL fileHandleNil = (fh == nil);
        if (fh) {
            @try {
                [fh seekToEndOfFile];
                [fh writeData:data];
                [fh closeFile];
                os_unfair_lock_unlock(&sLock);
                return YES;
            } @catch (...) {
            }
            [fh closeFile];
        }

        errno = 0;
        FILE *fp = fopen([path fileSystemRepresentation], "a");
        int fopenErrno = errno;
        if (fp) {
            const char *bytes = [lineStr UTF8String];
            if (bytes) {
                fputs(bytes, fp);
            }
            fclose(fp);
            os_unfair_lock_unlock(&sLock);
            return YES;
        }

        if (failureInfo) {
            *failureInfo = @{
                @"path": path ?: @"",
                @"baseDir": baseDir ?: @"",
                @"createdDir": @(createdDir),
                @"dirErrorDomain": dirError.domain ?: @"nil",
                @"dirErrorCode": @(dirError.code),
                @"createdFile": @(createdFile),
                @"fileHandleNil": @(fileHandleNil),
                @"fopenErrno": @(fopenErrno)
            };
        }
        NSLog(@"[TikTokClean] health write failed path=%@ baseDir=%@ createdDir=%d createFile=%d fileHandleNil=%d dirError=%@/%ld errno=%d",
              path,
              baseDir,
              createdDir,
              createdFile,
              fileHandleNil,
              dirError.domain ?: @"nil",
              (long)dirError.code,
              fopenErrno);
    }

    os_unfair_lock_unlock(&sLock);
    return NO;
}

static UIWindow *TCKeyWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;
    UIWindow *fallback = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if (!fallback) fallback = window;
            if (window.isKeyWindow) return window;
        }
    }
    return fallback;
}

static UIImage *TCSymbol(NSString *name) {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:17.0
                                                         weight:UIImageSymbolWeightSemibold];
    return [UIImage systemImageNamed:name withConfiguration:configuration];
}

static UIButton *TCMakeButton(CGRect frame, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = frame;
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.72];
    button.layer.cornerRadius = 6.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = UIColor.whiteColor.CGColor;
    button.clipsToBounds = YES;
    [button addTarget:gOverlayTarget action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

static void TCUpdateFullscreenImage(void) {
    NSString *name = gPureMode ? @"eye" : @"eye.slash";
    [gFullscreenButton setImage:TCSymbol(name) forState:UIControlStateNormal];
}

static void TCUpdateDownloadImage(void) {
    NSString *name = gDownloadBusy ? @"hourglass" : @"arrow.down";
    [gDownloadButton setImage:TCSymbol(name) forState:UIControlStateNormal];
    gDownloadButton.enabled = !gDownloadBusy;
    gDownloadButton.alpha = gDownloadBusy ? 0.65 : 1.0;
}

static void TCUpdateAutoScrollImage(void) {
    NSString *name = gAutoScrollEnabled ? @"chevron.down.2" : @"pause";
    [gAutoScrollButton setImage:TCSymbol(name) forState:UIControlStateNormal];
    gAutoScrollButton.alpha = gAutoScrollEnabled ? 1.0 : 0.65;
}

static void TCLayoutOverlay(void) {
    UIWindow *window = TCKeyWindow();
    if (!window || !gOverlay) return;

    CGFloat safeTop = window.safeAreaInsets.top;
    gOverlay.frame = CGRectMake(CGRectGetWidth(window.bounds) - 52.0, safeTop + 118.0, 40.0, 122.0);
}

static void TCEnsureOverlay(void) {
    UIWindow *window = TCKeyWindow();
    if (!window) return;

    if (!gOverlayTarget) gOverlayTarget = [[NSClassFromString(@"TCOverlayTarget") alloc] init];

    if (!gOverlay) {
        gOverlay = [[UIView alloc] initWithFrame:CGRectZero];
        gOverlay.backgroundColor = UIColor.clearColor;
        gOverlay.userInteractionEnabled = YES;
        gOverlay.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;

        gFullscreenButton = TCMakeButton(CGRectMake(15.0, 2.0, 20.0, 20.0), @selector(toggleFullscreen));
        gDownloadButton = TCMakeButton(CGRectMake(15.0, 46.0, 20.0, 20.0), @selector(downloadCurrentVideo));
        gAutoScrollButton = TCMakeButton(CGRectMake(15.0, 90.0, 20.0, 20.0), @selector(toggleAutoScroll));
        [gOverlay addSubview:gFullscreenButton];
        [gOverlay addSubview:gDownloadButton];
        [gOverlay addSubview:gAutoScrollButton];
        TCUpdateFullscreenImage();
        TCUpdateDownloadImage();
        TCUpdateAutoScrollImage();
    }

    if (gOverlay.superview != window) {
        [gOverlay removeFromSuperview];
        [window addSubview:gOverlay];
    }
    TCLayoutOverlay();
    [window bringSubviewToFront:gOverlay];
}

static void TCSetOverlayVisible(BOOL visible) {
    TCEnsureOverlay();
    gOverlay.hidden = !visible;
}

static void TCSetActiveFeedController(UIViewController *controller) {
    if (gActiveFeedController == controller) return;
    [gActiveFeedController release];
    gActiveFeedController = [controller retain];
}

static UIViewController *TCFindFeedController(UIViewController *controller) {
    Class feedClass = NSClassFromString(@"AWENewFeedTableViewController");
    UIViewController *cursor = controller;
    while (cursor) {
        if (feedClass && [cursor isKindOfClass:feedClass]) return cursor;
        cursor = cursor.parentViewController;
    }
    return gActiveFeedController;
}

static NSURL *TCFirstHTTPURL(id urlModel) {
    if (!urlModel) return nil;

    id list = TCInvokeObject(urlModel, @selector(originURLList));
    if (![list isKindOfClass:NSArray.class] || [list count] == 0) {
        list = TCInvokeObject(urlModel, @selector(URLList));
    }
    if (![list isKindOfClass:NSArray.class]) return nil;

    for (id value in (NSArray *)list) {
        NSURL *url = nil;
        if ([value isKindOfClass:NSURL.class]) {
            url = value;
        } else if ([value isKindOfClass:NSString.class]) {
            url = [NSURL URLWithString:value];
        }
        NSString *scheme = url.scheme.lowercaseString;
        if ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) return url;
    }
    return nil;
}

static UIViewController *TCVisibleViewController(void) {
    UIWindow *window = TCKeyWindow();
    if (!window) return nil;
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController) {
        controller = controller.presentedViewController;
    }
    return controller;
}

static NSString *TCVideoExtensionForURL(NSURL *sourceURL, NSString *mimeType) {
    NSString *urlExtension = sourceURL.pathExtension.lowercaseString;
    if (urlExtension.length &&
        ![urlExtension isEqualToString:@"tmp"] &&
        ![urlExtension isEqualToString:@"download"]) {
        return urlExtension;
    }

    NSString *lowerMimeType = mimeType.lowercaseString;
    if ([lowerMimeType isEqualToString:@"video/quicktime"]) {
        return @"mov";
    }
    if ([lowerMimeType hasPrefix:@"video/"]) {
        return @"mp4";
    }
    return @"mp4";
}

static void TCPresentDownloadSheet(NSURL *location, NSURL *sourceURL, NSString *mimeType) {
    if (!location) {
        TCFinishDownload(NO);
        return;
    }

    NSString *extension = TCVideoExtensionForURL(sourceURL, mimeType);
    NSURL *targetURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.%@", NSUUID.UUID.UUIDString, extension]]];
    NSError *moveError = nil;
    [[NSFileManager defaultManager] removeItemAtURL:targetURL error:nil];
    if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:targetURL error:&moveError]) {
        TCLog(@"Download staging failed error=%@/%ld", moveError.domain ?: @"nil", (long)moveError.code);
        TCFinishDownload(NO);
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = TCVisibleViewController();
        if (!presenter) {
            [[NSFileManager defaultManager] removeItemAtURL:targetURL error:nil];
            TCFinishDownload(NO);
            return;
        }

        UIActivityViewController *activity =
            [[[UIActivityViewController alloc] initWithActivityItems:@[targetURL]
                                              applicationActivities:nil] autorelease];
        activity.completionWithItemsHandler = ^(__unused UIActivityType activityType,
                                               __unused BOOL completed,
                                               NSArray *__unused returnedItems,
                                               __unused NSError *activityError) {
            [[NSFileManager defaultManager] removeItemAtURL:targetURL error:nil];
            TCLog(@"Share sheet finished completed=%d type=%@ error=%@/%ld",
                  completed,
                  activityType ?: @"nil",
                  activityError.domain ?: @"nil",
                  (long)activityError.code);
        };
        if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
            activity.popoverPresentationController.sourceView = presenter.view;
            activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds),
                                                                           CGRectGetMidY(presenter.view.bounds),
                                                                           1.0,
                                                                           1.0);
        }
        [presenter presentViewController:activity animated:YES completion:^{
            TCFinishDownload(YES);
        }];
    });
}

static NSURL *TCCurrentCleanVideoURL(id aweme, BOOL *videoURLFound, BOOL *downloadURLFound) {
    if (videoURLFound) *videoURLFound = NO;
    if (downloadURLFound) *downloadURLFound = NO;
    id video = TCInvokeObject(aweme, @selector(video));
    if (!video) {
        return nil;
    }

    id noWatermarkModel = TCInvokeObject(video, @selector(downloadNoWatermarkURL));
    NSURL *url = TCFirstHTTPURL(noWatermarkModel);
    if (downloadURLFound) *downloadURLFound = (url != nil);
    if (url) return url;

    id playModel = TCInvokeObject(video, @selector(playURL));
    url = TCFirstHTTPURL(playModel);
    if (videoURLFound) *videoURLFound = (url != nil);
    return url;
}

static void TCFinishDownload(BOOL success) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gDownloadBusy = NO;
        TCUpdateDownloadImage();

        UINotificationFeedbackGenerator *feedback =
            [[[UINotificationFeedbackGenerator alloc] init] autorelease];
        [feedback notificationOccurred:success
            ? UINotificationFeedbackTypeSuccess
            : UINotificationFeedbackTypeError];
    });
}

static BOOL TCAwemeIsAd(id aweme) {
    if (!aweme) return NO;
    if ([aweme respondsToSelector:@selector(isAds)] && TCInvokeBoolReturn(aweme, @selector(isAds))) return YES;
    if ([aweme respondsToSelector:@selector(isAdsOrPseudoAds)] && TCInvokeBoolReturn(aweme, @selector(isAdsOrPseudoAds))) return YES;
    if ([aweme respondsToSelector:@selector(adInfo)] && TCInvokeObject(aweme, @selector(adInfo))) return YES;
    if ([aweme respondsToSelector:@selector(adOrPseudoAdModel)] && TCInvokeObject(aweme, @selector(adOrPseudoAdModel))) return YES;
    if ([aweme respondsToSelector:@selector(adType)] && TCInvokeIntegerReturn(aweme, @selector(adType)) != 0) return YES;
    return NO;
}

static NSString *TCAwemeSkipReason(id aweme) {
    if (!aweme) return @"none";

    if ([aweme respondsToSelector:@selector(isAdsOrPseudoAds)] && TCInvokeBoolReturn(aweme, @selector(isAdsOrPseudoAds))) {
        return @"ad";
    }
    if ([aweme respondsToSelector:@selector(adInfo)] && TCInvokeObject(aweme, @selector(adInfo))) {
        return @"ad";
    }
    if ([aweme respondsToSelector:@selector(adOrPseudoAdModel)] && TCInvokeObject(aweme, @selector(adOrPseudoAdModel))) {
        return @"ad";
    }
    if ([aweme respondsToSelector:@selector(adType)] && TCInvokeIntegerReturn(aweme, @selector(adType)) != 0) {
        return @"ad";
    }
    if ([aweme respondsToSelector:@selector(isAds)] && TCInvokeBoolReturn(aweme, @selector(isAds))) {
        return @"ad";
    }
    return @"none";
}

static BOOL TCHCClassHasInstanceSelector(NSString *version, NSString *className, NSString *selectorName) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        TCHCLOG(@"TikTokClean health TikTok=%@ MISSING class=%@", version, className);
        return NO;
    }

    SEL sel = NSSelectorFromString(selectorName);
    if (![cls instancesRespondToSelector:sel]) {
        TCHCLOG(@"TikTokClean health TikTok=%@ MISSING class=%@ selector=%@", version, className, selectorName);
        return NO;
    }
    return YES;
}

static BOOL TCHCClassHasClassSelector(NSString *version, NSString *className, NSString *selectorName) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        TCHCLOG(@"TikTokClean health TikTok=%@ MISSING class=%@", version, className);
        return NO;
    }

    SEL sel = NSSelectorFromString(selectorName);
    if (![cls respondsToSelector:sel]) {
        TCHCLOG(@"TikTokClean health TikTok=%@ MISSING class=%@ selector=%@", version, className, selectorName);
        return NO;
    }
    return YES;
}

static void TCRunHealthCheck(void) {
    NSString *tiktokVersion = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"unknown";
    if (TCHCVersionAlreadyLogged(tiktokVersion)) return;

    BOOL missing = NO;
    missing |= !TCHCClassHasInstanceSelector(tiktokVersion, @"AWEFeedCellViewController", @"playerWillLoopPlaying:");
    missing |= !TCHCClassHasInstanceSelector(tiktokVersion, @"AWENewFeedTableViewController", @"scrollToNextVideo");
    missing |= !TCHCClassHasInstanceSelector(tiktokVersion, @"AWENewFeedTableViewController", @"currentAweme");
    missing |= !TCHCClassHasInstanceSelector(tiktokVersion, @"AWEFeedPlayerBottomProgressBar", @"didMoveToWindow");
    missing |= !TCHCClassHasInstanceSelector(tiktokVersion, @"AWEFeedPlayerBottomProgressBar", @"setHidden:");
    missing |= !TCHCClassHasInstanceSelector(tiktokVersion, @"AWEFeedPlayerBottomProgressBar", @"setAlpha:");

    missing |= !TCHCClassHasInstanceSelector(tiktokVersion, @"AWEAwemeModel", @"isAds");
    missing |= !TCHCClassHasInstanceSelector(tiktokVersion, @"AWEAwemeModel", @"isAdsOrPseudoAds");
    missing |= !TCHCClassHasInstanceSelector(tiktokVersion, @"AWEAwemeModel", @"adInfo");
    missing |= !TCHCClassHasInstanceSelector(tiktokVersion, @"AWEAwemeModel", @"adOrPseudoAdModel");
    missing |= !TCHCClassHasInstanceSelector(tiktokVersion, @"AWEAwemeModel", @"adType");

    missing |= !TCHCClassHasClassSelector(tiktokVersion, @"AWEAwemeModel", @"liveStreamURLJSONTransformer");
    missing |= !TCHCClassHasClassSelector(tiktokVersion, @"AWEAwemeModel", @"relatedLiveJSONTransformer");
    missing |= !TCHCClassHasClassSelector(tiktokVersion, @"AWEAwemeModel", @"rawModelFromLiveRoomModel:");
    missing |= !TCHCClassHasClassSelector(tiktokVersion, @"AWEAwemeModel", @"aweLiveRoom_subModelPropertyKey");

    if (!missing) {
        TCHCLOG(@"TikTokClean health TikTok=%@ OK", tiktokVersion);
    }
}

static void TCAttemptFeedSkip(NSString *__unused reason) {
    UIViewController *feed = gActiveFeedController;
    if (!feed) return;
    if (![feed respondsToSelector:@selector(scrollToNextVideo)]) return;
    TCInvokeVoid(feed, @selector(scrollToNextVideo));
}

static void TCAutoScrollAdvance(void) {
    UIViewController *feed = gActiveFeedController;
    if (!gAutoScrollEnabled) return;
    if (!feed) return;
    if (![feed respondsToSelector:@selector(scrollToNextVideo)]) return;
    TCInvokeVoid(feed, @selector(scrollToNextVideo));
}

static void TCStartDownload(void) {
    id aweme = TCInvokeObject(gActiveFeedController, @selector(currentAweme));
    BOOL videoURLFound = NO;
    BOOL downloadURLFound = NO;
    NSURL *url = TCCurrentCleanVideoURL(aweme, &videoURLFound, &downloadURLFound);
    if (!url) {
        TCFinishDownload(NO);
        return;
    }
    NSURL *requestURL = [[url retain] autorelease];

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = 30.0;
    configuration.timeoutIntervalForResource = 180.0;

    __block NSURLSession *session = nil;
    session = [NSURLSession sessionWithConfiguration:configuration];
    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *httpResponse = [response isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)response
                : nil;
            BOOL validStatus = !httpResponse || (httpResponse.statusCode >= 200 && httpResponse.statusCode < 300);
            BOOL validFile = location && !error && validStatus;
            if (!validFile) {
                [session finishTasksAndInvalidate];
                TCFinishDownload(NO);
                return;
            }
            [session finishTasksAndInvalidate];
            NSString *mimeType = response.MIMEType ?: @"";
            TCPresentDownloadSheet(location, requestURL, mimeType);
        }];
    [task resume];
}

@interface TCOverlayTarget : NSObject
- (void)toggleFullscreen;
- (void)downloadCurrentVideo;
- (void)toggleAutoScroll;
@end

@implementation TCOverlayTarget

- (void)toggleFullscreen {
    UIViewController *feed = gActiveFeedController;
    if (!feed) return;

    gPureMode = !gPureMode;
    TCInvokeBool(feed, @selector(setPureMode:), gPureMode);
    TCUpdateFullscreenImage();
    TCEnsureOverlay();
}

- (void)downloadCurrentVideo {
    if (gDownloadBusy) {
        return;
    }

    gDownloadBusy = YES;
    TCUpdateDownloadImage();

    TCStartDownload();
}

- (void)toggleAutoScroll {
    gAutoScrollEnabled = !gAutoScrollEnabled;
    TCUpdateAutoScrollImage();
}

@end

%hook AWENewFeedTableViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    TCSetActiveFeedController((UIViewController *)self);
    TCSetOverlayVisible(YES);
    TCInvokeBool(self, @selector(setPureMode:), gPureMode);
}

- (void)viewWillDisappear:(BOOL)animated {
    TCSetOverlayVisible(NO);
    %orig;
}

%end

%hook AWEFeedCellViewController

- (void)containerDidFullyDisplayWithReason:(NSInteger)reason {
    %orig;
    TCLog(@"Auto-scroll containerDidFullyDisplayWithReason triggered reason=%ld", (long)reason);
    UIViewController *feed = TCFindFeedController((UIViewController *)self);
    if (feed) {
        TCSetActiveFeedController(feed);
        TCSetOverlayVisible(YES);
    }
    id aweme = TCInvokeObject(feed, @selector(currentAweme));
    NSString *skipReason = TCAwemeSkipReason(aweme);
    TCLog(@"skip reason=%@", skipReason);
    if ([skipReason isEqualToString:@"ad"]) {
        TCAttemptFeedSkip(skipReason);
    }
}

- (void)playerWillLoopPlaying:(id)player {
    %orig;
    TCLog(@"Auto-scroll AWEFeedCellViewController playerWillLoopPlaying triggered");
    TCAutoScrollAdvance();
}

%end

%hook AWEFeedPlayerBottomProgressBar

- (void)didMoveToWindow {
    %orig;
    UIView *view = (UIView *)self;
    if (![view window]) return;
    if (!gProgressBarLogged) {
        TCLog(@"Progressbar found/forced visible class=%@", NSStringFromClass([self class]));
        gProgressBarLogged = YES;
    }
    view.hidden = NO;
    view.alpha = 1.0;
    [view.superview bringSubviewToFront:view];
}

- (void)setHidden:(BOOL)hidden {
    %orig(NO);
    UIView *view = (UIView *)self;
    if (hidden || view.hidden) {
        if (!gProgressBarLogged) {
            TCLog(@"Progressbar found/forced visible class=%@", NSStringFromClass([self class]));
            gProgressBarLogged = YES;
        }
        view.alpha = 1.0;
        [view.superview bringSubviewToFront:view];
    }
}

- (void)setAlpha:(CGFloat)alpha {
    %orig(1.0);
    if (alpha != 1.0) {
        UIView *view = (UIView *)self;
        if (!gProgressBarLogged) {
            TCLog(@"Progressbar found/forced visible class=%@", NSStringFromClass([self class]));
            gProgressBarLogged = YES;
        }
        view.hidden = NO;
        [view.superview bringSubviewToFront:view];
    }
}

%end

%hook AWEAwemeModel

- (id)init {
    id result = %orig;
    if (TCAwemeIsAd(result)) {
        TCLog(@"model block reason=ad");
        [result release];
        return nil;
    }
    return result;
}

- (id)initWithDictionary:(id)dictionary error:(NSError **)error {
    id result = %orig;
    if (TCAwemeIsAd(result)) {
        TCLog(@"model block reason=ad");
        [result release];
        return nil;
    }
    return result;
}

+ (id)live_callInitWithDictyCategoryMethod:(id)__unused dictionary {
    TCLog(@"live transformer blocked=live_callInitWithDictyCategoryMethod:");
    return nil;
}

+ (id)liveStreamURLJSONTransformer {
    TCLog(@"live transformer blocked=liveStreamURLJSONTransformer");
    return nil;
}

+ (id)relatedLiveJSONTransformer {
    TCLog(@"live transformer blocked=relatedLiveJSONTransformer");
    return nil;
}

+ (id)rawModelFromLiveRoomModel:(id)__unused roomModel {
    TCLog(@"live transformer blocked=rawModelFromLiveRoomModel:");
    return nil;
}

+ (id)aweLiveRoom_subModelPropertyKey {
    TCLog(@"live transformer blocked=aweLiveRoom_subModelPropertyKey");
    return nil;
}

%end

%ctor {
    @autoreleasepool {
        TCRunHealthCheck();
        [[NSNotificationCenter defaultCenter] addObserverForName:@"AVPlayerItemDidPlayToEndTimeNotification"
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            TCAutoScrollAdvance();
        }];
        TCLog(@"Loaded for TikTok %@", NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"]);
    }
}
