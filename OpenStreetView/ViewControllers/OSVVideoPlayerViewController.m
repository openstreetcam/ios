//
//  OSVVideoPlayerViewController.m
//  OpenStreetView
//
//  Created by Bogdan Sala on 12/05/16.
//  Copyright © 2016 Bogdan Sala. All rights reserved.
//

#import "OSVVideoPlayerViewController.h"
#import "OSVVideoPlayer.h"
#import "OSVSyncController.h"
#import "OSVPolyline.h"
#import "UIColor+OSVColor.h"
#import "UIViewController+Additions.h"
#import "OSVPhotoPlayer.h"

#import "OSVServerSequence.h"
#import "OSVFullScreenAnimationController.h"
#import "OSVDissmissFullScreenAnimationController.h"
#import "OSVFullScreenImageViewController.h"
#import "NSAttributedString+Additions.h"

#import <SKMaps/SKMaps.h>

#import "OSVScoreDetailsView.h"
#import "OSVScoreHistory.h"
#import "OSVUserDefaults.h"

#import "OSVUtils.h"

#import "OSC-Swift.h"

@interface OSVVideoPlayerViewController () <OSVPlayerDelegate, UIViewControllerTransitioningDelegate, OSVFullScreenImageViewControllerDelegate, UIGestureRecognizerDelegate>

@property (weak, nonatomic) IBOutlet UIButton       *playButton;
@property (strong, nonatomic) SKMapView             *mapView;
@property (weak, nonatomic) IBOutlet UILabel        *dateLabel;
@property (weak, nonatomic) IBOutlet UILabel        *frameIndexLabel;
@property (weak, nonatomic) IBOutlet UIImageView    *frameIndexImage;
@property (weak, nonatomic) IBOutlet UISlider       *basicSlider;
@property (weak, nonatomic) IBOutlet UIButton       *fullScreenButton;
@property (weak, nonatomic) IBOutlet UIButton       *deletePhotoButton;
@property (weak, nonatomic) IBOutlet UILabel        *pointsLabel;
@property (weak, nonatomic) IBOutlet UIButton       *pointsButton;

@property (strong, nonatomic) id<OSVPlayer>         player;
@property (assign, nonatomic) NSInteger             frameIndex;
@property (assign, nonatomic) NSInteger             totalCount;

@property (assign, nonatomic) CGRect                prevFrame;

@property (assign, nonatomic) NSInteger             startingFrameIndex;
@property (assign, nonatomic) BOOL                  willShowFullScreen;

@property (strong, nonatomic) OSVFullScreenAnimationController          *presentFullScreenAnimationController;
@property (strong, nonatomic) OSVDissmissFullScreenAnimationController  *dissmissFullScreenAnimationController;

@property (strong, nonatomic) id savedGestureRecognizerDelegate;

@property (weak, nonatomic) IBOutlet OSVScoreDetailsView    *scoreDetails;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint     *detailsLeading;
@property (weak, nonatomic) IBOutlet UIView                 *circleAnimation;
@property (weak, nonatomic) IBOutlet UIView                 *mapViewContainer;

@end

@implementation OSVVideoPlayerViewController

-  (void)viewDidLoad {
    [super viewDidLoad];
    if ([OSVUserDefaults sharedInstance].enableMap) {
        self.mapView = [[SKMapView alloc] initWithFrame:self.mapViewContainer.bounds];
    }
    [UIViewController addMapView:self.mapView toView:self.mapViewContainer];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"MMM d*"];
    NSString *dtext = [[formatter stringFromDate:self.selectedSequence.dateAdded] stringByReplacingOccurrencesOfString:@"*" withString:[self daySuffixForDate:self.selectedSequence.dateAdded]];
    [formatter setDateFormat:@" | HH:mm a"];
    NSString *htext = [formatter stringFromDate:self.selectedSequence.dateAdded];
    
    self.dateLabel.attributedText = [NSAttributedString combineString:dtext withSize:12.f color:[UIColor whiteColor] fontName:@"HelveticaNeue"
                                                          withString:htext withSize:12.f color:[UIColor colorWithHex:0x6e707b] fontName:@"HelveticaNeue"];
    OSVPhoto *photo = self.selectedSequence.photos.firstObject;
    
    SKCoordinateRegion reg;
    reg.zoomLevel = 10;
    reg.center = photo.photoData.location.coordinate;
    [self.mapView setVisibleRegion:reg];
    
    if (!self.player) {
        if ([self.selectedSequence isKindOfClass:[OSVServerSequence class]]||
             [self.selectedSequence isKindOfClass:[OSVServerSequencePart class]]) {
            if (self.selectedSequence.photos.count) {
                self.player = [[OSVPhotoPlayer alloc] initWithView:self.videoPlayerPreview andSlider:self.basicSlider];
            } else {
                [[OSVSyncController sharedInstance].tracksController getPhotosForTrack:self.selectedSequence withCompletionBlock:^(id<OSVSequence> seq, NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.player = [[OSVPhotoPlayer alloc] initWithView:self.videoPlayerPreview andSlider:self.basicSlider];
                        self.player.delegate = self;
                        if (self.player.currentPlayableItem != self.selectedSequence.photos) {
                            [self.player prepareForPlayableItem:self.selectedSequence.photos startingFromIndex:self.startingFrameIndex];
                            [self zoomOnSequence:self.selectedSequence];
                            [self addSequenceOnMap:self.selectedSequence];
                        }
                    });
                }];
            }
        } else {
            self.player = [[OSVVideoPlayer alloc] initWithView:self.videoPlayerPreview andSlider:self.basicSlider];
            self.deletePhotoButton.hidden = YES;
        }
    }
    
    self.mapView.settings.showAccuracyCircle = NO;
    self.mapView.settings.showCurrentPosition = NO;
    self.mapView.mapScaleView.hidden = YES;
    
    self.player.delegate = self;
    self.transitioningDelegate = self;
    self.presentFullScreenAnimationController = [OSVFullScreenAnimationController new];
    self.dissmissFullScreenAnimationController = [OSVDissmissFullScreenAnimationController new];
    self.navigationController.navigationBar.hidden = YES;
    self.savedGestureRecognizerDelegate = self.navigationController.interactivePopGestureRecognizer.delegate;
    self.navigationController.interactivePopGestureRecognizer.delegate = self;
    self.videoPlayerPreview.layer.borderColor = [[UIColor colorWithHex:0x6e707b] colorWithAlphaComponent:0.3].CGColor;
    self.videoPlayerPreview.layer.borderWidth = 1;
    self.videoPlayerPreview.layer.cornerRadius = 3;
    
    if ([OSVUserDefaults sharedInstance].useGamification &&
        ![self.selectedSequence isKindOfClass:[OSVServerSequencePart class]]) {
        NSString *pointsString = [@(((OSVSequence *)self.selectedSequence).points) stringValue];
        if (((OSVSequence *)self.selectedSequence).points > 9999) {
            pointsString = [NSString  stringWithFormat:@"%ldK", ((OSVSequence *)self.selectedSequence).points/1000];
        }
        NSAttributedString *points = [NSAttributedString combineString:pointsString
                                                              withSize:16.f
                                                                 color:[UIColor whiteColor]
                                                              fontName:@"HelveticaNeue"
                                                            withString:@"\npts"
                                                              withSize:10.f
                                                                 color:[UIColor whiteColor]
                                                              fontName:@"HelveticaNeue"];
        self.pointsLabel.attributedText = points;
        self.pointsButton.hidden = NO;
        self.pointsLabel.hidden = NO;
        self.scoreDetails.hidden = NO;
        self.circleAnimation.hidden = NO;
    } else {
        self.pointsLabel.text = @"";
        self.pointsButton.hidden = YES;
        self.pointsLabel.hidden = YES;
        self.scoreDetails.hidden = YES;
        self.circleAnimation.hidden = YES;
    }
    
    self.scoreDetails.alpha = 0;
    self.circleAnimation.layer.cornerRadius = self.circleAnimation.frame.size.width/2.0;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self enlageMultiplyerWithCompletion:^{
            [UIView animateWithDuration:0.2 animations:^{
                self.pointsButton.transform = CGAffineTransformIdentity;
                self.pointsLabel.transform = CGAffineTransformIdentity;
                self.circleAnimation.transform = CGAffineTransformIdentity;
            } completion:^(BOOL finished) {
                [self enlageMultiplyerWithCompletion:^{
                    [self diminishMultiplyerWithCompletion:^{
                        
                    }];
                }];
            }];
        }];
    });
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    if (self.frameIndex == 0) {
        if ([self.selectedSequence isKindOfClass:[OSVServerSequence class]]||
            [self.selectedSequence isKindOfClass:[OSVServerSequencePart class]]) {
            if (self.player.currentPlayableItem != self.selectedSequence.photos) {
                [self.player prepareForPlayableItem:self.selectedSequence.photos startingFromIndex:self.startingFrameIndex];
            }
        } else {
            [self.player prepareForPlayableItem:[OSVUtils fileNameForTrackID:self.selectedSequence.uid] startingFromIndex:self.startingFrameIndex];
        }
        [self.player play];
        [self.player pause];
        
        if (self.player.currentPlayableItem != self.selectedSequence.photos) {
            [self zoomOnSequence:self.selectedSequence];
            [self addSequenceOnMap:self.selectedSequence];
        }
        self.startingFrameIndex = 0;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (!self.willShowFullScreen) {
        self.navigationController.navigationBar.hidden = NO;
        self.navigationController.interactivePopGestureRecognizer.delegate = self.savedGestureRecognizerDelegate;
    }
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"presentFullScreen"]) {
        OSVFullScreenImageViewController *vc = segue.destinationViewController;
        vc.delegate = self;
        vc.sequenceDatasource = self.selectedSequence;
        vc.selectedIndexPath = [NSIndexPath indexPathForItem:self.frameIndex-1 inSection:0];
        vc.transitioningDelegate = self;
    }
}

#pragma mark - Orientation

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        self.player.playerLayer.frame = self.videoPlayerPreview.bounds;
        self.player.playerLayer.position = CGPointMake(CGRectGetMidX(self.videoPlayerPreview.bounds), CGRectGetMidY(self.videoPlayerPreview.bounds));
        self.player.imageView.frame = self.videoPlayerPreview.bounds;
    } completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
    }];
}

#pragma mark - Actions

- (IBAction)play:(id)sender {
    if (self.player.isPlaying) {
        [self.player pause];
        self.playButton.selected = NO;
    } else {
        self.playButton.selected = YES;
        if (self.player.currentPlayableItem) {
            [self.player resume];
        } else {
            [self.player prepareForPlayableItem:[OSVUtils fileNameForTrackID:self.selectedSequence.uid] startingFromIndex:self.startingFrameIndex];
            [self.player play];
        }
    }
}

- (IBAction)fastForward:(id)sender {
    [self.player fastForward];
    self.playButton.selected = YES;
}

- (IBAction)fastBackword:(id)sender {
    [self.player fastBackward];
    self.playButton.selected = YES;
}

- (IBAction)nextFrame:(id)sender {
    [self.player pause];
    [self.player displayNextFrame];
    self.playButton.selected = NO;
}

- (IBAction)backFrame:(id)sender {
    [self.player pause];
    [self.player displayPreviousFrame];
    self.playButton.selected = NO;
}

- (IBAction)back:(id)sender {
    if (self.navigationController) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:^{
            
        }];
    }
}

- (IBAction)fullScreen:(id)sender {
    [self performSegueWithIdentifier:@"presentFullScreen" sender:self];
}

- (IBAction)didTapDelete:(id)sender {
    if (self.selectedSequence.photos.count > 0 && self.frameIndex > 0 && self.selectedSequence.photos.count >= self.frameIndex) {
        [[OSVSyncController sharedInstance].tracksController deletePhoto:self.selectedSequence.photos[self.frameIndex - 1] withCompletionBlock:^(NSError *error) {
            [self.selectedSequence.photos removeObjectAtIndex:self.frameIndex-1];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.player prepareForPlayableItem:self.selectedSequence.photos startingFromIndex:self.frameIndex - 1];
            });
        }];
    }
}
#pragma mark - Public

- (void)displayFrameAtIndex:(NSInteger)frameindex {
    self.startingFrameIndex = frameindex;
}

#pragma mark - Private

- (void)zoomOnSequence:(id<OSVSequence>)seq {
    SKBoundingBox *box = [SKBoundingBox new];
    box.topLeftCoordinate = seq.topLeftCoordinate;
    box.bottomRightCoordinate = seq.bottomRightCoordinate;
    
    [self.mapView fitBounds:box withInsets:UIEdgeInsetsMake(20, 20, 20, 20)];
}

- (void)addSequenceOnMap:(id<OSVSequence>)sequence {
    
    [self orderPhotosIntoSequence:sequence];
    NSArray *track = [self getTrackForSequence:sequence];
    
    OSVPolyline *polyline = [OSVPolyline new];
    polyline.lineWidth = 6;
    polyline.backgroundLineWidth = 6;
    polyline.coordinates = track;
    polyline.identifier = (int)sequence.uid;
    
    if ([sequence isKindOfClass:[OSVSequence class]]) {
        polyline.fillColor = [UIColor blackColor];
        polyline.strokeColor = [UIColor blackColor];
        polyline.isLocal = YES;
    } else {
        polyline.fillColor = [UIColor blackColor];
        polyline.strokeColor = [UIColor blackColor];
        polyline.isLocal = NO;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.mapView addPolyline:polyline];
    });
}

- (void)orderPhotosIntoSequence:(OSVSequence *)sequence {
    sequence.photos = [NSMutableArray arrayWithArray:[sequence.photos sortedArrayUsingComparator:^NSComparisonResult(id<OSVPhoto> photoA, id<OSVPhoto> photoB) {
        NSInteger first = photoA.photoData.sequenceIndex;
        NSInteger second = photoB.photoData.sequenceIndex;
        if (first < second) {
            return NSOrderedAscending;
        } else if (first == second) {
            return NSOrderedSame;
        } else {
            return NSOrderedDescending;
        }
    }]];
}

- (NSMutableArray *)getTrackForSequence:(id<OSVSequence>)sequence {
    
    NSMutableArray *positions = [NSMutableArray array];
    CLLocationCoordinate2D topLeftCoordinate = CLLocationCoordinate2DMake(1000, -1000);
    CLLocationCoordinate2D bottomRightCoordinate = CLLocationCoordinate2DMake(-1000, 1000);
    
    if ([sequence isKindOfClass:[OSVSequence class]] || !sequence.track.count) {
        for (OSVPhoto *photo in sequence.photos) {
            CLLocation *location = photo.photoData.location;
            
            [positions addObject:location];
            if (topLeftCoordinate.latitude > location.coordinate.latitude ) {
                topLeftCoordinate.latitude = location.coordinate.latitude;
            }
            
            if (topLeftCoordinate.longitude < location.coordinate.longitude) {
                topLeftCoordinate.longitude = location.coordinate.longitude;
            }
            
            if (bottomRightCoordinate.latitude < location.coordinate.latitude) {
                bottomRightCoordinate.latitude = location.coordinate.latitude;
            }
            
            if (bottomRightCoordinate.longitude > location.coordinate.longitude) {
                bottomRightCoordinate.longitude = location.coordinate.longitude;
            }
        }
    } else {
        for (CLLocation *location in sequence.track) {
            CLLocation *location1 = [[CLLocation alloc] initWithCoordinate:location.coordinate altitude:0.0 horizontalAccuracy:0.0 verticalAccuracy:0.0 course:location.course speed:0.0 timestamp:[NSDate new]];
            [positions addObject:location1];
            if (topLeftCoordinate.latitude > location.coordinate.latitude ) {
                topLeftCoordinate.latitude = location.coordinate.latitude;
            }
            
            if (topLeftCoordinate.longitude < location.coordinate.longitude) {
                topLeftCoordinate.longitude = location.coordinate.longitude;
            }
            
            if (bottomRightCoordinate.latitude < location.coordinate.latitude) {
                bottomRightCoordinate.latitude = location.coordinate.latitude;
            }
            
            if (bottomRightCoordinate.longitude > location.coordinate.longitude) {
                bottomRightCoordinate.longitude = location.coordinate.longitude;
            }
        }
    }
    
    sequence.topLeftCoordinate = topLeftCoordinate;
    sequence.bottomRightCoordinate = bottomRightCoordinate;
    
    return positions;
}

#pragma mark - Private

- (NSString *)daySuffixForDate:(NSDate *)date {
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSInteger dayOfMonth = [calendar component:NSCalendarUnitDay fromDate:date];
    switch (dayOfMonth) {
        case 1:
        case 21:
        case 31: return @"st";
        case 2:
        case 22: return @"nd";
        case 3:
        case 23: return @"rd";
        default: return @"th";
    }
}

#pragma mark - Player Delegate 

- (void)didDisplayFrameAtIndex:(NSInteger)frameIndex {
    self.frameIndex = frameIndex;
    NSString *frameI = [NSString stringWithFormat:@" / %ld IMG", (long)self.totalCount];
    self.frameIndexLabel.attributedText = [NSAttributedString combineString:[@(frameIndex) stringValue] withSize:12.f color:[UIColor whiteColor] fontName:@"HelveticaNeue"
                                                                 withString:frameI withSize:12.f color:[UIColor colorWithHex:0x6e707b] fontName:@"HelveticaNeue"];
    if (frameIndex < self.selectedSequence.photos.count) {
        OSVPhoto *photo = self.selectedSequence.photos[frameIndex];
        UIImageView *annotationView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"icon_point_position"]];
        
        SKAnnotation *currentAnnotation = [SKAnnotation annotation];
        currentAnnotation.annotationView = [[SKAnnotationView alloc] initWithView:annotationView reuseIdentifier:@"currentAnnotation"];
        currentAnnotation.location = photo.photoData.location.coordinate;
        currentAnnotation.identifier = INT_MAX;
        
        [self.mapView addAnnotation:currentAnnotation withAnimationSettings:[SKAnimationSettings animationSettings]];
    }
}

- (void)totalNumberOfFrames:(NSInteger)totalFrames {
    self.totalCount = totalFrames;
    NSString *frameI = [NSString stringWithFormat:@" / %ld IMG", (long)self.totalCount];
    self.frameIndexLabel.attributedText = [NSAttributedString combineString:[@(self.frameIndex) stringValue] withSize:12.f color:[UIColor whiteColor] fontName:@"HelveticaNeue"
                                                                 withString:frameI withSize:12.f color:[UIColor colorWithHex:0x6e707b] fontName:@"HelveticaNeue"];
}

#pragma mark - Transition delegate

- (id <UIViewControllerAnimatedTransitioning>)animationControllerForPresentedController:(UIViewController *)presented presentingController:(UIViewController *)presenting sourceController:(UIViewController *)source {
    if ([presented isKindOfClass:[OSVFullScreenImageViewController class]]) {
        self.presentFullScreenAnimationController.originFrame = self.player.imageView.frame;
        self.presentFullScreenAnimationController.player = self.player;
        self.willShowFullScreen = YES;
        self.fullScreenButton.hidden = YES;
        self.frameIndexLabel.hidden = YES;
        self.frameIndexImage.hidden = YES;
        self.dateLabel.hidden = YES;
        self.videoPlayerPreview.layer.borderWidth = 0;

        return self.presentFullScreenAnimationController;
    }
    
    return nil;
}

- (id <UIViewControllerAnimatedTransitioning>)animationControllerForDismissedController:(UIViewController *)dismissed {
    if ([dismissed isKindOfClass:[OSVFullScreenImageViewController class]]) {
        self.willShowFullScreen = NO;
        self.fullScreenButton.hidden = NO;
        self.frameIndexLabel.hidden = NO;
        self.frameIndexImage.hidden = NO;
        self.dateLabel.hidden = NO;
        self.videoPlayerPreview.layer.borderWidth = 1;

        CGPoint imageViewPoint = self.presentFullScreenAnimationController.fullScreeFrame.origin;
        
        CGRect imageViewRect;
        
        if ([self.selectedSequence isKindOfClass:[OSVServerSequence class]]) {
            imageViewRect = CGRectMake(-imageViewPoint.x, -imageViewPoint.y, self.presentFullScreenAnimationController.originFrame.size.width, self.presentFullScreenAnimationController.originFrame.size.height);
        } else {
            imageViewRect = CGRectMake(0, -imageViewPoint.y, self.presentFullScreenAnimationController.originFrame.size.width, self.presentFullScreenAnimationController.originFrame.size.height);
            self.player.imageView.hidden = YES;
        }
        
        self.dissmissFullScreenAnimationController.destinationFrame = imageViewRect;
        
        return self.dissmissFullScreenAnimationController;
    }
    return nil;
}
#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.navigationController.interactivePopGestureRecognizer) {
        return NO;
    }
    
    return YES;
}

#pragma mark - OSVFullScreenImageViewControllerDelegate

- (void)willDissmissViewController:(OSVFullScreenImageViewController *)vc {
    NSInteger index = vc.selectedIndexPath.item;
    if (index != NSNotFound) {
        [self.player displayFrameAtIndex:index];
    }
}

- (IBAction)didTapTrackDetails:(id)sender {
    if ([self.selectedSequence isKindOfClass:[OSVServerSequence class]]) {
        OSVServerSequence *seq = self.selectedSequence;
        self.scoreDetails.totalPointsLabel.text = [NSString stringWithFormat:NSLocalizedString(@"Total Points: %ld", @""), seq.points];
        
        int i = 0;
        [seq.scoreHistory sortUsingComparator:^NSComparisonResult(OSVScoreHistory *obj1, OSVScoreHistory *obj2) {
            if (obj1.multiplier < obj2.multiplier) {
                return NSOrderedAscending;
            } else {
                return NSOrderedDescending;
            }
        }];
        
        for (OSVScoreHistory *sch in seq.scoreHistory) {
            self.scoreDetails.pointsLabels[i].text = [@(sch.points) stringValue];
            self.scoreDetails.pointsLabels[i].hidden = NO;
            self.scoreDetails.multiplierLabels[i].text = [@(sch.multiplier) stringValue];
            self.scoreDetails.multiplierLabels[i].hidden = NO;
            self.scoreDetails.distanceLabels[i].text = [NSString stringWithFormat:@"%ld", sch.photos];
            self.scoreDetails.distanceLabels[i].hidden = NO;
            i++;
        }
    }
    
    if ([self.selectedSequence isKindOfClass:[OSVSequence class]]) {

        OSVSequence *seq = self.selectedSequence;
        self.scoreDetails.totalPointsLabel.text = [NSString stringWithFormat:NSLocalizedString(@"Total Points: %ld", @""), seq.points];
        
        int i = 0;
        [seq.scoreHistory sortUsingComparator:^NSComparisonResult(OSVScoreHistory *obj1, OSVScoreHistory *obj2) {
            if (obj1.multiplier < obj2.multiplier) {
                return NSOrderedAscending;
            } else {
                return NSOrderedDescending;
            }
        }];
        
        for (OSVScoreHistory *sch in seq.scoreHistory) {
            
            self.scoreDetails.pointsLabels[i].text = [@(sch.points) stringValue];
            self.scoreDetails.pointsLabels[i].hidden = NO;
            self.scoreDetails.multiplierLabels[i].text = sch.multiplier ? [@(sch.multiplier) stringValue] : NSLocalizedString(@"no connection", @"");
            self.scoreDetails.multiplierLabels[i].hidden = NO;
            self.scoreDetails.distanceLabels[i].text = [NSString stringWithFormat:@"%ld", sch.photos];
            self.scoreDetails.distanceLabels[i].hidden = NO;

            i++;
        }
        self.scoreDetails.disclosureLabel.hidden = NO;
        self.scoreDetails.disclosureLabel.text = NSLocalizedString(@"", @"");
    }
    
    if (![self.selectedSequence isKindOfClass:[OSVServerSequencePart class]]) {
        
        self.circleAnimation.transform = CGAffineTransformIdentity;
        
        [UIView animateWithDuration:0.3 animations:^{
            self.circleAnimation.transform = CGAffineTransformMakeScale(20, 20);
        } completion:^(BOOL finished) {
            [UIView animateWithDuration:0.1 delay:0.0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                self.scoreDetails.alpha = 1;
            } completion:^(BOOL finished) {
                
            }];
        }];
    }
}

- (IBAction)didTapDissmissDetails:(id)sender {
    [UIView animateWithDuration:0.1 animations:^{
        self.scoreDetails.alpha = 0;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.3 delay:0.1 options:UIViewAnimationOptionCurveEaseOut animations:^{
            self.circleAnimation.transform = CGAffineTransformIdentity;
        } completion:^(BOOL finished) {
            
        }];
    }];
}

- (void)enlageMultiplyerWithCompletion:(void (^)(void))completion {
    
    self.pointsLabel.transform = CGAffineTransformIdentity;
    self.pointsButton.transform = CGAffineTransformIdentity;
    self.circleAnimation.transform = CGAffineTransformIdentity;
    [UIView animateWithDuration:0.15 animations:^{
        self.pointsLabel.transform = CGAffineTransformMakeScale(1.25, 1.25);
        self.pointsButton.transform = CGAffineTransformMakeScale(1.25, 1.25);
        self.circleAnimation.transform = CGAffineTransformMakeScale(1.25, 1.25);
    } completion:^(BOOL finished) {
        if (finished) {
            completion();
        }
    }];
}

- (void)diminishMultiplyerWithCompletion:(void (^)(void))completion {
    
    [UIView animateWithDuration:0.7
                          delay:0.0
         usingSpringWithDamping:0.10
          initialSpringVelocity:0.2
                        options:UIViewAnimationOptionCurveLinear animations:^{
                            self.pointsLabel.transform = CGAffineTransformIdentity;
                            self.pointsButton.transform = CGAffineTransformIdentity;
                            self.circleAnimation.transform = CGAffineTransformIdentity;
                        } completion:^(BOOL finished) {
                            if (finished) {
                                completion();
                            }
                        }];
}

@end
