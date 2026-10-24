#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Independent experimental Instagram tweak. RyukGram itself is not modified.
static NSString *const kNames = @"CPHideCommentUsernames";
static NSString *const kAvatars = @"CPHideCommentAvatars";
static char kGesture, kPriorAlpha;
static IMP originalMove, originalTableLayout, originalCollectionLayout;
static IMP originalSetLabel, originalSetIdentifier;

static NSString *lower(NSString *s) {
    return [[s ?: @"" lowercaseString] stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
static BOOL enabled(NSString *key) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:key];
}
static BOOL commentButton(UIView *v) {
    if (!v.window || v.hidden || !v.userInteractionEnabled || v.alpha == 0) return NO;
    NSString *cls = lower(NSStringFromClass([v class]));
    NSString *label = lower(v.accessibilityLabel);
    NSString *ident = lower(v.accessibilityIdentifier);
    NSString *title = [v isKindOfClass:[UIButton class]]
        ? lower([(UIButton *)v titleForState:UIControlStateNormal]) : @"";
    BOOL isButton = [v isKindOfClass:[UIControl class]] ||
        (v.accessibilityTraits & UIAccessibilityTraitButton) ||
        [cls containsString:@"button"];
    if (!isButton) return NO;
    for (NSString *bad in @[@"reply", @"yanıtla", @"send", @"gönder",
                             @"composer", @"input", @"write"]) {
        if ([cls containsString:bad] || [ident containsString:bad]) return NO;
    }
    if ([cls containsString:@"commentbutton"] ||
        [cls containsString:@"commentsbutton"]) return YES;
    for (NSString *s in @[label, ident, title]) {
        if ([s isEqualToString:@"comment"] || [s isEqualToString:@"comments"] ||
            [s isEqualToString:@"yorum"] || [s isEqualToString:@"yorumlar"] ||
            [s hasPrefix:@"view comments"] || [s hasPrefix:@"view all comments"] ||
            [s hasPrefix:@"yorumları gör"] || [s hasPrefix:@"tüm yorumları"] ||
            [s hasPrefix:@"add a comment"] || [s hasPrefix:@"yorum ekle"] ||
            [s hasSuffix:@" comments"] || [s hasPrefix:@"comment,"] ||
            [s hasPrefix:@"comments,"] || [s hasPrefix:@"yorum,"]) return YES;
    }
    return NO;
}
static BOOL commentRow(UIView *v) {
    NSString *name = lower(NSStringFromClass([v class]));
    BOOL comment = [name containsString:@"comment"] || [name containsString:@"yorum"];
    BOOL row = [name containsString:@"cell"] || [name containsString:@"row"] ||
               [name containsString:@"item"];
    BOOL excluded = [name containsString:@"button"] || [name containsString:@"header"] ||
                    [name containsString:@"footer"] || [name containsString:@"composer"] ||
                    [name containsString:@"input"] || [name containsString:@"preview"];
    return comment && row && !excluded && v.bounds.size.width > 100;
}
static void privateAlpha(UIView *v, BOOL hide) {
    NSNumber *prior = objc_getAssociatedObject(v, &kPriorAlpha);
    if (hide) {
        if (!prior) objc_setAssociatedObject(v, &kPriorAlpha,
                            @(v.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (v.alpha != 0) v.alpha = 0;
    } else if (prior) {
        v.alpha = prior.doubleValue;
        objc_setAssociatedObject(v, &kPriorAlpha, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
static void collect(UIView *v, NSMutableArray<UILabel *> *labels,
                    NSMutableArray<UIView *> *images, NSUInteger depth) {
    if (depth > 9) return;
    for (UIView *c in v.subviews) {
        if ([c isKindOfClass:[UILabel class]]) [labels addObject:(UILabel *)c];
        NSString *cls = lower(NSStringFromClass([c class]));
        if ([c isKindOfClass:[UIImageView class]] || [cls containsString:@"avatar"] ||
            [cls containsString:@"profilepicture"] || [cls containsString:@"profileimage"])
            [images addObject:c];
        collect(c, labels, images, depth + 1);
    }
}
static BOOL username(NSString *s) {
    if (s.length == 0 || s.length > 30) return NO;
    static NSCharacterSet *valid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        valid = [NSCharacterSet characterSetWithCharactersInString:
                 @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._"];
    });
    if ([s rangeOfCharacterFromSet:valid.invertedSet].location != NSNotFound) return NO;
    if ([s rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound)
        return NO;
    return ![@[@"reply", @"like", @"likes", @"view", @"more", @"edited", @"follow",
                @"author", @"yanıtla", @"beğen", @"takip"] containsObject:lower(s)];
}
static void applyRow(UIView *row) {
    if (!commentRow(row)) return;
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    NSMutableArray<UIView *> *images = [NSMutableArray array];
    collect(row, labels, images, 0);
    UIView *avatar = nil;
    CGFloat bestAvatar = CGFLOAT_MAX;
    for (UIView *v in images) {
        if (!v.superview) continue;
        CGRect r = [v convertRect:v.bounds toView:row];
        CGFloat w = CGRectGetWidth(r), h = CGRectGetHeight(r);
        if (w < 14 || h < 14 || w > 65 || h > 65 ||
            CGRectGetMinY(r) < -10 || CGRectGetMinY(r) > 110) continue;
        CGFloat score = CGRectGetMinX(r) + 1.5 * CGRectGetMinY(r) + fabs(w - h);
        if (score < bestAvatar) { avatar = v; bestAvatar = score; }
    }
    UILabel *author = nil;
    CGFloat bestAuthor = CGFLOAT_MAX;
    CGRect avatarRect = avatar ? [avatar convertRect:avatar.bounds toView:row] : CGRectNull;
    for (UILabel *v in labels) {
        NSString *s = v.text ?: v.attributedText.string;
        if (!username(s)) continue;
        CGRect r = [v convertRect:v.bounds toView:row];
        if (CGRectGetMinY(r) < -5 || CGRectGetMinY(r) > 110) continue;
        CGFloat score = CGRectGetMinY(r) + 0.2 * CGRectGetMinX(r);
        if (avatar) {
            CGFloat dx = CGRectGetMinX(r) - CGRectGetMaxX(avatarRect);
            CGFloat dy = fabs(CGRectGetMidY(r) - CGRectGetMidY(avatarRect));
            if (dx < -8 || dx > 85 || dy > 45) continue;
            score = dy + 0.5 * fabs(dx - 12);
        }
        if (score < bestAuthor) { author = v; bestAuthor = score; }
    }
    for (UILabel *v in labels) {
        if (v != author && objc_getAssociatedObject(v, &kPriorAlpha))
            privateAlpha(v, NO);
    }
    for (UIView *v in images) {
        if (v != avatar && objc_getAssociatedObject(v, &kPriorAlpha))
            privateAlpha(v, NO);
    }
    if (author) privateAlpha(author, enabled(kNames));
    if (avatar) privateAlpha(avatar, enabled(kAvatars));
}
static void walk(UIView *v, NSUInteger depth) {
    if (depth > 25) return;
    if (commentRow(v)) applyRow(v);
    for (UIView *c in v.subviews) walk(c, depth + 1);
}
static void refresh(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *w in [UIApplication sharedApplication].windows) walk(w, 0);
    });
}

@interface CPMenu : UITableViewController
@end
@implementation CPMenu
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Comment Privacy";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self action:@selector(closeMenu)];
    self.tableView.rowHeight = 61;
    UILabel *footer = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, 270, 70)];
    footer.text = @"Only detected post and Reels comment rows. Other screens are unchanged.";
    footer.textColor = [UIColor secondaryLabelColor];
    footer.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    footer.textAlignment = NSTextAlignmentCenter;
    footer.numberOfLines = 0;
    self.tableView.tableFooterView = footer;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 2;
}
- (UITableViewCell *)tableView:(UITableView *)tableView
        cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"privacy"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"privacy"];
    BOOL isName = indexPath.row == 0;
    cell.textLabel.text = isName ? @"Hide Comment Usernames" : @"Hide Comment Avatars";
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.8;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.accessibilityIdentifier = isName ? kNames : kAvatars;
    sw.on = enabled(sw.accessibilityIdentifier);
    [sw addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}
- (void)changed:(UISwitch *)sw {
    [[NSUserDefaults standardUserDefaults] setBool:sw.isOn
                                            forKey:sw.accessibilityIdentifier];
    refresh();
}
- (void)closeMenu { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

static UIViewController *topController(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]] ||
                scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) { window = candidate; break; }
            }
            if (window) break;
        }
    }
    if (!window) window = app.keyWindow ?: app.windows.firstObject;
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}
@interface CPAction : NSObject
+ (instancetype)shared;
- (void)open:(UILongPressGestureRecognizer *)press;
@end
@implementation CPAction
+ (instancetype)shared {
    static CPAction *target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ target = [[CPAction alloc] init]; });
    return target;
}
- (void)open:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan) return;
    UIViewController *top = topController();
    if (!top || [top isKindOfClass:[UIAlertController class]] ||
        [top isKindOfClass:[CPMenu class]] ||
        ([top isKindOfClass:[UINavigationController class]] &&
         [[(UINavigationController *)top topViewController] isKindOfClass:[CPMenu class]]))
        return;
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[CPMenu alloc] init]];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [top presentViewController:nav animated:YES completion:nil];
}
@end
static void attach(UIView *v) {
    if (objc_getAssociatedObject(v, &kGesture) || !commentButton(v)) return;
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[CPAction shared] action:@selector(open:)];
    press.minimumPressDuration = 0.55;
    press.cancelsTouchesInView = YES;
    [v addGestureRecognizer:press];
    objc_setAssociatedObject(v, &kGesture, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void didMove(UIView *self, SEL cmd) {
    ((void (*)(id, SEL))originalMove)(self, cmd);
    if (!self.window) return;
    attach(self);
    if (commentRow(self)) {
        __weak UIView *weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *row = weak;
            if (row.window) applyRow(row);
        });
    }
}
static void setLabel(UIView *self, SEL cmd, NSString *label) {
    ((void (*)(id, SEL, id))originalSetLabel)(self, cmd, label);
    if (self.window) attach(self);
}
static void setIdentifier(UIView *self, SEL cmd, NSString *value) {
    ((void (*)(id, SEL, id))originalSetIdentifier)(self, cmd, value);
    if (self.window) attach(self);
}
static void tableLayout(UITableViewCell *self, SEL cmd) {
    ((void (*)(id, SEL))originalTableLayout)(self, cmd);
    if (commentRow(self)) applyRow(self);
}
static void collectionLayout(UICollectionViewCell *self, SEL cmd) {
    ((void (*)(id, SEL))originalCollectionLayout)(self, cmd);
    if (commentRow(self)) applyRow(self);
}
static void swapMethod(Class cls, SEL selector, IMP replacement, IMP *old) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    IMP inherited = method_getImplementation(method);
    if (class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)))
        *old = inherited;
    else
        *old = method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
}
__attribute__((constructor)) static void initializeCommentPrivacy(void) {
    @autoreleasepool {
        NSBundle *bundle = [NSBundle mainBundle];
        if (![[lower(bundle.bundlePath.pathExtension) lowercaseString] isEqualToString:@"app"])
            return;
        NSString *name = lower([bundle objectForInfoDictionaryKey:@"CFBundleExecutable"]);
        NSString *identifier = lower(bundle.bundleIdentifier);
        if (![name containsString:@"instagram"] && ![identifier containsString:@"instagram"])
            return;
        dispatch_async(dispatch_get_main_queue(), ^{
            swapMethod([UIView class], @selector(didMoveToWindow),
                       (IMP)didMove, &originalMove);
            swapMethod([UIView class], @selector(setAccessibilityLabel:),
                       (IMP)setLabel, &originalSetLabel);
            swapMethod([UIView class], @selector(setAccessibilityIdentifier:),
                       (IMP)setIdentifier, &originalSetIdentifier);
            swapMethod([UITableViewCell class], @selector(layoutSubviews),
                       (IMP)tableLayout, &originalTableLayout);
            swapMethod([UICollectionViewCell class], @selector(layoutSubviews),
                       (IMP)collectionLayout, &originalCollectionLayout);
            NSLog(@"[CommentPrivacy] loaded; both toggles default OFF");
        });
    }
}
