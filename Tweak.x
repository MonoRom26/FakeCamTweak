#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

static AVAssetReader *assetReader = nil;
static AVAssetReaderTrackOutput *trackOutput = nil;
static NSURL *selectedVideoURL = nil;
static BOOL isFakeCamEnabled = NO;
static NSMutableSet *hookedDelegateClasses = nil;

#pragma mark - Video Reader & Frame Replacement

void setupVideoReader(void) {
    if (!selectedVideoURL || ![[NSFileManager defaultManager] fileExistsAtPath:selectedVideoURL.path]) {
        return;
    }

    if (assetReader) {
        [assetReader cancelReading];
        assetReader = nil;
        trackOutput = nil;
    }

    AVAsset *asset = [AVAsset assetWithURL:selectedVideoURL];
    NSError *error = nil;
    assetReader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (error || !assetReader) return;

    AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!videoTrack) return;

    NSDictionary *outputSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    };

    trackOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:outputSettings];
    trackOutput.alwaysCopiesSampleData = NO;

    if ([assetReader canAddOutput:trackOutput]) {
        [assetReader addOutput:trackOutput];
        [assetReader startReading];
    }
}

CMSampleBufferRef getNextReplacementFrame(CMSampleBufferRef originalBuffer) {
    if (!isFakeCamEnabled || !selectedVideoURL) return NULL;

    if (!assetReader || assetReader.status != AVAssetReaderStatusReading) {
        setupVideoReader();
    }

    CMSampleBufferRef nextBuffer = [trackOutput copyNextSampleBuffer];

    // Loop seamlessly when video reaches the end
    if (!nextBuffer && assetReader.status == AVAssetReaderStatusCompleted) {
        setupVideoReader();
        nextBuffer = [trackOutput copyNextSampleBuffer];
    }

    if (!nextBuffer) return NULL;

    CMSampleTimingInfo timingInfo;
    CMSampleBufferGetSampleTimingInfo(originalBuffer, 0, &timingInfo);

    CMSampleBufferRef adjustedBuffer = NULL;
    CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, nextBuffer, 1, &timingInfo, &adjustedBuffer);

    CFRelease(nextBuffer);
    return adjustedBuffer;
}

#pragma mark - Dynamic AVCaptureVideoDataOutput Delegate Hooking

static void (*orig_captureOutput_didOutputSampleBuffer_fromConnection)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *);

void replaced_captureOutput_didOutputSampleBuffer_fromConnection(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
    if (isFakeCamEnabled && selectedVideoURL && [output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
        CMSampleBufferRef fakeBuffer = getNextReplacementFrame(sampleBuffer);
        if (fakeBuffer) {
            orig_captureOutput_didOutputSampleBuffer_fromConnection(self, _cmd, output, fakeBuffer, connection);
            CFRelease(fakeBuffer);
            return;
        }
    }
    orig_captureOutput_didOutputSampleBuffer_fromConnection(self, _cmd, output, sampleBuffer, connection);
}

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (sampleBufferDelegate) {
        Class delegateClass = [sampleBufferDelegate class];
        if (!hookedDelegateClasses) {
            hookedDelegateClasses = [NSMutableSet new];
        }
        if (![hookedDelegateClasses containsObject:delegateClass]) {
            SEL targetSel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
            Method method = class_getInstanceMethod(delegateClass, targetSel);
            if (method) {
                orig_captureOutput_didOutputSampleBuffer_fromConnection = (void *)method_getImplementation(method);
                method_setImplementation(method, (IMP)replaced_captureOutput_didOutputSampleBuffer_fromConnection);
                [hookedDelegateClasses addObject:delegateClass];
            }
        }
    }
    %orig;
}

%end

#pragma mark - Photo Library Picker Controller

@interface FakeCamPickerHandler : NSObject <PHPickerViewControllerDelegate>
+ (instancetype)sharedInstance;
- (void)presentVideoPicker;
@end

@implementation FakeCamPickerHandler

+ (instancetype)sharedInstance {
    static FakeCamPickerHandler *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FakeCamPickerHandler alloc] init];
    });
    return instance;
}

- (UIViewController *)topViewController {
    UIWindow *keyWindow = nil;
    for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *window in scene.windows) {
                if (window.isKeyWindow) {
                    keyWindow = window;
                    break;
                }
            }
        }
    }
    UIViewController *topVC = keyWindow.rootViewController;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    return topVC;
}

- (void)presentVideoPicker {
    dispatch_async(dispatch_get_main_queue(), ^{
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.selectionLimit = 1;
        config.filter = [PHPickerFilter videosFilter];

        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = self;

        UIViewController *topVC = [self topViewController];
        if (topVC) {
            [topVC presentViewController:picker animated:YES completion:nil];
        }
    });
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];

    if (results.count == 0) {
        // User tapped Cancel -> disable fake cam and return to real camera
        isFakeCamEnabled = NO;
        return;
    }

    PHPickerResult *result = results.firstObject;
    if ([result.itemProvider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
        [result.itemProvider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL * _Nullable url, NSError * _Nullable error) {
            if (url && !error) {
                // Copy video into TikTok's tmp folder before iOS deletes the temporary picker URL
                NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"fakecam_active.mp4"];
                NSURL *destURL = [NSURL fileURLWithPath:destPath];

                NSFileManager *fm = [NSFileManager defaultManager];
                [fm removeItemAtURL:destURL error:nil];

                NSError *copyError = nil;
                if ([fm copyItemAtURL:url toURL:destURL error:&copyError]) {
                    selectedVideoURL = destURL;
                    isFakeCamEnabled = YES;
                    setupVideoReader();
                }
            }
        }];
    }
}

@end

#pragma mark - 3-Finger Triple-Tap Gesture Trigger on UIWindow

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    static BOOL gestureAdded = NO;
    if (!gestureAdded) {
        gestureAdded = YES;
        UITapGestureRecognizer *tripleTap = [[UITapGestureRecognizer alloc] initWithTarget:[FakeCamPickerHandler sharedInstance] action:@selector(presentVideoPicker)];
        tripleTap.numberOfTapsRequired = 3;
        tripleTap.numberOfTouchesRequired = 3;
        [self addGestureRecognizer:tripleTap];
    }
}

%end
