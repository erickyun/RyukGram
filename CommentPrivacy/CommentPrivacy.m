#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Independent experimental Instagram tweak. RyukGram itself is not modified.
static NSString *const kNames = @"CPHideCommentUsernames";
static NSString *const kAvatars = @"CPHideCommentAvatars";
static char kGesture, kPriorAlpha, kInlineOriginal, kInlineRendered;
static IMP originalMove, originalTableLayout, originalCollectionLayout, originalAnyLayout;
static IMP originalSetLabel, originalSetIdentifier, originalLabelText, originalLabelAttributed;
static BOOL changingRenderedText = NO;

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
               [name containsString:@"item"] || [name containsString:@"commentnode"] ||
               [name hasSuffix:@"commentview"];
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
// Modern Instagram comments can display the bold username and the comment body
// in the SAME attributed view. The original implementation only hid UILabel
// instances containing an entire username; it could never hide an inline author.
static BOOL cpTextView(UIView *v) {
    if ([v isKindOfClass:[UILabel class]] || [v isKindOfClass:[UITextView class]])
        return YES;
    NSString *cls = lower(NSStringFromClass([v class]));
    if (![cls containsString:@"text"] && ![cls containsString:@"label"] &&
        ![cls containsString:@"styled"]) return NO;
    return [v respondsToSelector:@selector(attributedText)] ||
           [v respondsToSelector:NSSelectorFromString(@"attributedString")] ||
           [v respondsToSelector:NSSelectorFromString(@"styledString")] ||
           [v respondsToSelector:@selector(text)];
}
static NSAttributedString *cpAttributed(UIView *v) {
    for (NSString *key in @[@"attributedText", @"attributedString"]) {
        SEL getter = NSSelectorFromString(key);
        if (![v respondsToSelector:getter]) continue;
        @try {
            id result = ((id (*)(id, SEL))objc_msgSend)(v, getter);
            if ([result isKindOfClass:[NSAttributedString class]]) return result;
        } @catch (NSException *exception) {}
    }
    // IGCoreTextView is a UIView whose text is held by IGStyledString;
    // it is not a UILabel and commonly has no attributedText property.
    if ([v respondsToSelector:NSSelectorFromString(@"styledString")]) {
        @try {
            id styled = ((id (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"styledString"));
            if ([styled respondsToSelector:NSSelectorFromString(@"attributedString")]) {
                id value = ((id (*)(id, SEL))objc_msgSend)(styled, NSSelectorFromString(@"attributedString"));
                if ([value isKindOfClass:[NSAttributedString class]]) return value;
            }
        } @catch (NSException *exception) {}
    }
    return nil;
}
static NSString *cpString(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        return l.text ?: l.attributedText.string;
    }
    if ([v isKindOfClass:[UITextView class]]) {
        UITextView *t = (UITextView *)v;
        return t.text ?: t.attributedText.string;
    }
    SEL getter = @selector(text);
    if ([v respondsToSelector:getter]) {
        @try {
            id result = ((id (*)(id, SEL))objc_msgSend)(v, getter);
            if ([result isKindOfClass:[NSString class]]) return result;
        } @catch (NSException *exception) {}
    }
    return cpAttributed(v).string;
}
static BOOL cpSetAttributed(UIView *v, NSAttributedString *value) {
    for (NSString *name in @[@"setAttributedText:", @"setAttributedString:"]) {
        SEL setter = NSSelectorFromString(name);
        if (![v respondsToSelector:setter]) continue;
        @try {
            changingRenderedText = YES;
            ((void (*)(id, SEL, id))objc_msgSend)(v, setter, value);
            changingRenderedText = NO;
            return YES;
        } @catch (NSException *exception) {
            changingRenderedText = NO;
        }
    }
    // IGCoreTextView uses setStyledString:, which expects an IGStyledString
    // wrapper rather than an NSAttributedString. Copy before editing to avoid
    // mutating a shared/cached styled string belonging to other comments.
    SEL getter = NSSelectorFromString(@"styledString");
    SEL setter = NSSelectorFromString(@"setStyledString:");
    SEL attrSetter = NSSelectorFromString(@"setAttributedString:");
    if ([v respondsToSelector:getter] && [v respondsToSelector:setter]) {
        @try {
            id styled = ((id (*)(id, SEL))objc_msgSend)(v, getter);
            if (styled && [styled conformsToProtocol:@protocol(NSCopying)]) {
                id copied = [styled copy];
                if ([copied respondsToSelector:attrSetter]) {
                    changingRenderedText = YES;
                    ((void (*)(id, SEL, id))objc_msgSend)(copied, attrSetter, [value mutableCopy]);
                    ((void (*)(id, SEL, id))objc_msgSend)(v, setter, copied);
                    changingRenderedText = NO;
                    return YES;
                }
            }
        } @catch (NSException *exception) {
            changingRenderedText = NO;
        }
    }
    return NO;
}
static NSAttributedString *cpOriginalAttributed(UIView *v) {
    NSAttributedString *current = cpAttributed(v);
    NSAttributedString *stored = objc_getAssociatedObject(v, &kInlineOriginal);
    NSAttributedString *rendered = objc_getAssociatedObject(v, &kInlineRendered);
    if (stored && rendered && current &&
        ([current isEqualToAttributedString:rendered] ||
         [current.string isEqualToString:rendered.string]))
        return stored;
    if (stored) {
        objc_setAssociatedObject(v, &kInlineOriginal, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(v, &kInlineRendered, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return current;
}
static void cpRestoreInline(UIView *v) {
    NSAttributedString *original = objc_getAssociatedObject(v, &kInlineOriginal);
    NSAttributedString *rendered = objc_getAssociatedObject(v, &kInlineRendered);
    if (!original) return;
    NSAttributedString *current = cpAttributed(v);
    BOOL unchanged = rendered && current &&
        ([current isEqualToAttributedString:rendered] ||
         [current.string isEqualToString:rendered.string]);
    objc_setAssociatedObject(v, &kInlineOriginal, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(v, &kInlineRendered, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (unchanged) cpSetAttributed(v, original);
}
static void cpReplaceInline(UIView *v, NSAttributedString *original, NSRange prefix) {
    if (!original || prefix.length == 0 || NSMaxRange(prefix) >= original.length) return;
    NSMutableAttributedString *masked = [original mutableCopy];
    [masked deleteCharactersInRange:prefix];
    NSAttributedString *result = [masked copy];
    NSAttributedString *rendered = objc_getAssociatedObject(v, &kInlineRendered);
    NSAttributedString *current = cpAttributed(v);
    if (rendered && current &&
        ([current isEqualToAttributedString:result] ||
         [current.string isEqualToString:result.string])) return;
    objc_setAssociatedObject(v, &kInlineOriginal, [original copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(v, &kInlineRendered, result, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!cpSetAttributed(v, result)) cpRestoreInline(v);
}
static void collect(UIView *v, NSMutableArray<UIView *> *texts,
                    NSMutableArray<UIView *> *images, NSUInteger depth) {
    if (depth > 12) return;
    for (UIView *c in v.subviews) {
        if (cpTextView(c)) [texts addObject:c];
        NSString *cls = lower(NSStringFromClass([c class]));
        if ([c isKindOfClass:[UIImageView class]] || [cls containsString:@"avatar"] ||
            [cls containsString:@"profilepicture"] || [cls containsString:@"profileimage"])
            [images addObject:c];
        collect(c, texts, images, depth + 1);
    }
}
static BOOL username(NSString *value) {
    NSString *s = [value stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"@"]) s = [s substringFromIndex:1];
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
                @"author", @"yanıtla", @"beğen", @"takip", @"translate",
                @"replies", @"comments", @"ago"] containsObject:lower(s)];
}
static BOOL cpBoldFont(id font) {
    if (![font isKindOfClass:[UIFont class]]) return NO;
    UIFont *f = font;
    BOOL trait = (f.fontDescriptor.symbolicTraits & UIFontDescriptorTraitBold) != 0;
    NSString *fontName = lower(f.fontName);
    return trait || [fontName containsString:@"bold"] ||
           [fontName containsString:@"semibold"] || [fontName containsString:@"demi"];
}
// Returns the range to delete ONLY when the author is a distinct styled prefix.
static NSRange cpAuthorPrefix(NSAttributedString *text) {
    if (!text || text.length < 4) return NSMakeRange(NSNotFound, 0);
    NSString *s = text.string;
    NSUInteger i = 0;
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    while (i < s.length && [ws characterIsMember:[s characterAtIndex:i]]) i++;
    NSUInteger start = i;
    if (start > 2) return NSMakeRange(NSNotFound, 0);
    while (i < s.length && ![ws characterIsMember:[s characterAtIndex:i]] &&
           i - start <= 31) i++;
    if (i == s.length || !username([s substringWithRange:NSMakeRange(start, i - start)]))
        return NSMakeRange(NSNotFound, 0);
    NSUInteger wordEnd = i;
    while (i < s.length && [ws characterIsMember:[s characterAtIndex:i]]) i++;
    if (i == s.length || i == wordEnd) return NSMakeRange(NSNotFound, 0);
    // A username must have a different style/link than the actual comment body.
    NSUInteger authorIndex = start;
    NSUInteger bodyIndex = i;
    UIFont *beforeFont = [text attribute:NSFontAttributeName atIndex:authorIndex effectiveRange:NULL];
    UIFont *bodyFont = [text attribute:NSFontAttributeName atIndex:bodyIndex effectiveRange:NULL];
    id authorLink = [text attribute:NSLinkAttributeName atIndex:authorIndex effectiveRange:NULL];
    id bodyLink = [text attribute:NSLinkAttributeName atIndex:bodyIndex effectiveRange:NULL];
    BOOL styledAuthor = (cpBoldFont(beforeFont) && !cpBoldFont(bodyFont)) ||
                        (authorLink && !bodyLink);
    if (!styledAuthor) return NSMakeRange(NSNotFound, 0);
    return NSMakeRange(0, i);
}
static void applyRow(UIView *row) {
    if (changingRenderedText || !commentRow(row)) return;
    NSMutableArray<UIView *> *texts = [NSMutableArray array];
    NSMutableArray<UIView *> *images = [NSMutableArray array];
    collect(row, texts, images, 0);
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
    UIView *author = nil;
    BOOL inlineAuthor = NO;
    NSRange authorPrefix = NSMakeRange(NSNotFound, 0);
    NSAttributedString *authorOriginal = nil;
    CGFloat bestAuthor = CGFLOAT_MAX;
    CGRect avatarRect = avatar ? [avatar convertRect:avatar.bounds toView:row] : CGRectNull;
    for (UIView *v in texts) {
        NSAttributedString *original = cpOriginalAttributed(v);
        NSString *s = original.string ?: cpString(v);
        BOOL isolated = username(s);
        NSRange prefix = isolated ? NSMakeRange(NSNotFound, 0) : cpAuthorPrefix(original);
        if (!isolated && prefix.location == NSNotFound) continue;
        CGRect r = [v convertRect:v.bounds toView:row];
        if (CGRectGetMinY(r) < -8 || CGRectGetMinY(r) > 120) continue;
        CGFloat score = CGRectGetMinY(r) + 0.15 * CGRectGetMinX(r);
        if (!isolated) score += 25; // A standalone author label is more trustworthy.
        if (avatar) {
            CGFloat dx = CGRectGetMinX(r) - CGRectGetMaxX(avatarRect);
            CGFloat dy = fabs(CGRectGetMinY(r) - CGRectGetMinY(avatarRect));
            if (dx < -15 || dx > 145 || dy > 65) continue;
            score = dy + 0.2 * fabs(dx - 12) + (isolated ? 0 : 25);
        }
        if (score < bestAuthor) {
            bestAuthor = score;
            author = v;
            inlineAuthor = !isolated;
            authorPrefix = prefix;
            authorOriginal = original;
        }
    }
    BOOL hideNames = enabled(kNames);
    BOOL hideAvatars = enabled(kAvatars);
    for (UIView *v in texts) {
        if (!hideNames || v != author || inlineAuthor) privateAlpha(v, NO);
        if (!hideNames || v != author || !inlineAuthor) cpRestoreInline(v);
    }
    for (UIView *v in images) {
        if (v != avatar || !hideAvatars) privateAlpha(v, NO);
    }
    if (hideNames && author) {
        if (inlineAuthor) cpReplaceInline(author, authorOriginal, authorPrefix);
        else privateAlpha(author, YES);
    }
    if (avatar) privateAlpha(avatar, hideAvatars);
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
static void genericLayout(UIView *self, SEL cmd) {
    ((void (*)(id, SEL))originalAnyLayout)(self, cmd);
    if (!changingRenderedText && self.window && commentRow(self)) applyRow(self);
}
static void refreshFromLabel(UILabel *label) {
    if (changingRenderedText || !enabled(kNames) || !label.window) return;
    UIView *parent = label.superview;
    for (NSUInteger depth = 0; parent && depth < 14; depth++, parent = parent.superview) {
        if (!commentRow(parent)) continue;
        __weak UIView *weakRow = parent;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *row = weakRow;
            if (row.window) applyRow(row);
        });
        break;
    }
}
static void labelText(UILabel *self, SEL cmd, NSString *value) {
    ((void (*)(id, SEL, id))originalLabelText)(self, cmd, value);
    refreshFromLabel(self);
}
static void labelAttributed(UILabel *self, SEL cmd, NSAttributedString *value) {
    ((void (*)(id, SEL, id))originalLabelAttributed)(self, cmd, value);
    refreshFromLabel(self);
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
            swapMethod([UIView class], @selector(layoutSubviews),
                       (IMP)genericLayout, &originalAnyLayout);
            swapMethod([UILabel class], @selector(setText:),
                       (IMP)labelText, &originalLabelText);
            swapMethod([UILabel class], @selector(setAttributedText:),
                       (IMP)labelAttributed, &originalLabelAttributed);
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
