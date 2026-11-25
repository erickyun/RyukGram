#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>

// Independent experimental Instagram tweak. RyukGram itself is not modified.
static NSString *const kNames = @"CPHideCommentUsernames";
static NSString *const kAvatars = @"CPHideCommentAvatars";
static NSString *const kReelNames = @"CPHideReelUsernames";
static NSString *const kReelAvatars = @"CPHideReelProfilePictures";
static NSString *const kReelAudio = @"CPHideReelAudioThumbnail";
static char kGesture, kPriorAlpha, kInlineOriginal, kInlineRendered;
static IMP originalMove, originalTableLayout, originalCollectionLayout, originalAnyLayout;
static IMP originalSetLabel, originalSetIdentifier, originalLabelText, originalLabelAttributed;
static IMP originalAudioImage, originalAudioControllerLayout;
static IMP originalTransientHidden, originalTransientContents, originalTransientAnimation;
static IMP originalNativeLayout, originalNativeMove, originalNativeSuperview;
static IMP originalNativeBounds, originalNativeFrame;
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

// Reels author controls. Restrict modifications to native Sundial viewer
// *author* controls, never generic labels/images in posts, Explore or DMs.
// Old Instagram exposes IGSundialViewerUserButton with userNameLabel and
// profilePictureImageView; newer releases can use nested attribution wrappers.
static BOOL cpReelOverlayRoot(UIView *v) {
    NSString *n = lower(NSStringFromClass(v.class));
    return [n containsString:@"sundial"] &&
           [n containsString:@"viewer"] &&
           ([n containsString:@"videocontrolsoverlay"] ||
            [n containsString:@"controlsoverlayview"]);
}
static BOOL cpReelAuthorRoot(UIView *v) {
    NSString *n = lower(NSStringFromClass(v.class));
    BOOL sundial = [n containsString:@"sundialviewer"] ||
                   ([n containsString:@"sundial"] && [n containsString:@"reel"]);
    if (!sundial) return NO;
    return [n containsString:@"userbutton"] ||
           [n containsString:@"userattribution"] ||
           [n containsString:@"creatorattribution"] ||
           [n containsString:@"authorattribution"] ||
           [n containsString:@"creatorheader"] ||
           [n containsString:@"collaboratorattribution"] ||
           [n containsString:@"collabauthor"] ||
           [n containsString:@"coauthor"];
}
static id cpSafeGetter(id object, NSString *property) {
    if (!object || !property.length) return nil;
    SEL getter = NSSelectorFromString(property);
    if (![object respondsToSelector:getter]) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, getter); }
    @catch (NSException *exception) { return nil; }
}
static UIView *cpReelSubView(id parent, NSString *property) {
    id candidate = cpSafeGetter(parent, property);
    if (![candidate isKindOfClass:[UIView class]]) return nil;
    UIView *view = parent;
    if (![view isKindOfClass:[UIView class]] || ![(UIView *)candidate isDescendantOfView:view])
        return nil;
    return candidate;
}
static NSString *cpReelModelName(id author) {
    id usernameValue = cpSafeGetter(author, @"userName");
    if (![usernameValue isKindOfClass:[NSString class]]) {
        id user = cpSafeGetter(author, @"user");
        usernameValue = cpSafeGetter(user, @"username");
    }
    NSString *name = [usernameValue isKindOfClass:[NSString class]]
                     ? (NSString *)usernameValue : nil;
    if ([name hasPrefix:@"@"]) name = [name substringFromIndex:1];
    return username(name) ? name : nil;
}
static BOOL cpReelNameMatches(UIView *view, NSString *modelName) {
    NSString *text = [cpString(view) stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length || !username(text)) return NO;
    if ([text hasPrefix:@"@"]) text = [text substringFromIndex:1];
    return modelName.length && [text isEqualToString:modelName];
}
static void cpGatherReel(UIView *v, NSMutableArray<UIView *> *texts,
                         NSMutableArray<UIView *> *pictures, NSUInteger depth) {
    if (depth > 8) return;
    for (UIView *child in v.subviews) {
        NSString *cls = lower(NSStringFromClass(child.class));
        if (cpTextView(child)) [texts addObject:child];
        BOOL avatar = [cls containsString:@"profilepicture"] ||
                      [cls containsString:@"profilepic"] ||
                      [cls containsString:@"avatar"];
        if (avatar) [pictures addObject:child];
        cpGatherReel(child, texts, pictures, depth + 1);
    }
}

// Collab reels can expose a single label "alice and bob", or separate
// author labels and a stack of overlapping profile-picture views.
static BOOL cpReelCombinedNames(NSString *value) {
    if (!value.length || value.length > 240) return NO;
    NSMutableString *clean = [value mutableCopy];
    for (NSString *mark in @[@"\u2066", @"\u2067", @"\u2068", @"\u2069",
                              @"\u200E", @"\u200F", @"\u202A", @"\u202C"])
        [clean replaceOccurrencesOfString:mark withString:@"" options:0
                                    range:NSMakeRange(0, clean.length)];
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *name = @"@?[A-Za-z0-9._]{1,30}";
        NSString *separator = @"(?:\\s+(?:and|ve|und|et|y|e|en)\\s+|\\s*[,&·+]\\s*)";
        // Instagram abbreviates three or more creators as "alice and 2
        // others". The count phrase is NOT an Instagram username.
        NSString *count = @"(?:[0-9]+\\s+(?:others?|other\\s+people|kişi|diğer\\s+kişi|weitere|autres|más|otros?|outras?|outros?|anderen))";
        NSString *countSeparator = @"(?:\\s+(?:and|ve|und|et|y|e|en)\\s+|\\s*[&+]\\s*)";
        NSString *pattern = [NSString stringWithFormat:
            @"^\\s*%@(?:%@%@)*%@%@\\s*$|^\\s*%@(?:%@%@)+\\s*$",
            name, separator, name, countSeparator, count,
            name, separator, name];
        re = [NSRegularExpression regularExpressionWithPattern:pattern
                    options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    if ([re numberOfMatchesInString:clean options:0
                              range:NSMakeRange(0,clean.length)] == 0) return NO;
    // The pattern is for author handles, not metadata or controls.
    NSString *l = lower(clean);
    for (NSString *bad in @[@"from openai", @"see more", @"follow", @"view all",
                             @"original audio", @"paid partnership"])
        if ([l isEqualToString:bad]) return NO;
    return YES;
}
// A count can also be a separate text view next to the first author's
// label. Only use this matcher on the already-confirmed author line.
static BOOL cpReelCountSuffix(NSString *value) {
    if (!value.length || value.length > 64) return NO;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
            @"^\\s*(?:(?:and|ve|und|et|y|e|en|&|\\+)\\s*)?[0-9]+\\s+(?:others?|other\\s+people|kişi|diğer\\s+kişi|weitere|autres|más|otros?|outras?|outros?|anderen)\\s*$"
            options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    return [re numberOfMatchesInString:value options:0 range:NSMakeRange(0,value.length)] > 0;
}
static BOOL cpReelAuthorText(NSString *s) {
    return username(s) || cpReelCombinedNames(s);
}
static BOOL cpSmallReelPortrait(UIView *v, UIView *root, CGRect *outRect) {
    if (!v.superview) return NO;
    CGRect r = [v convertRect:v.bounds toView:root];
    CGFloat w = r.size.width, h = r.size.height;
    if (w < 13 || h < 13 || w > 100 || h > 100 ||
        fabs(w-h) > MAX(w,h)*0.42) return NO;
    if (outRect) *outRect = r;
    return YES;
}
static void cpCollectCollabPortraits(UIView *root, UIView *v,
                                     NSMutableOrderedSet<UIView *> *typed,
                                     NSMutableOrderedSet<UIView *> *generic,
                                     NSUInteger depth) {
    if (depth > 10) return;
    NSString *cls = lower(NSStringFromClass(v.class));
    BOOL isPortrait = [cls containsString:@"profilepicture"] ||
                      [cls containsString:@"profilepic"] ||
                      [cls containsString:@"avatar"];
    BOOL isImage = [v isKindOfClass:[UIImageView class]] ||
                   [cls containsString:@"igimageview"];
    if (cpSmallReelPortrait(v, root, NULL)) {
        if (isPortrait) [typed addObject:v];
        else if (isImage) [generic addObject:v];
    }
    // Only access known portrait properties, never arbitrary media models.
    if (depth == 0 || cpReelAuthorRoot(v) || isPortrait ||
        [cls containsString:@"collab"] || [cls containsString:@"coauthor"]) {
        for (NSString *getter in @[@"profilePictureImageView", @"profilePictureView",
                                   @"profilePicView", @"avatarImageView", @"avatarView",
                                   @"primaryAvatarView", @"secondaryAvatarView",
                                   @"primaryProfilePictureView", @"secondaryProfilePictureView",
                                   @"collaboratorAvatarView", @"collaboratorProfilePictureView"]) {
            UIView *candidate = cpReelSubView(v, getter);
            if (candidate && cpSmallReelPortrait(candidate, root, NULL))
                [typed addObject:candidate];
        }
    }
    for (UIView *child in v.subviews)
        cpCollectCollabPortraits(root, child, typed, generic, depth + 1);
}
static BOOL cpCollabNearPortrait(CGRect label, CGRect avatar) {
    CGFloat dx = CGRectGetMinX(label) - CGRectGetMaxX(avatar);
    CGFloat dy = fabs(CGRectGetMidY(label) - CGRectGetMidY(avatar));
    return label.size.width >= 12 && label.size.height >= 8 &&
           label.size.height <= 58 && dx >= -15 && dx <= 180 &&
           dy <= MAX(22.0, avatar.size.height * 0.8);
}
// Weak tracking permits restoring even when Instagram has rebound a cell
// and no longer exposes the same Collab layout.
static NSHashTable<UIView *> *cpCollabNames;
static NSHashTable<UIView *> *cpCollabPictures;
static void cpCollabAlpha(UIView *view, BOOL hide, BOOL isName) {
    NSHashTable<UIView *> *views = isName ? cpCollabNames : cpCollabPictures;
    if (!views && hide) {
        views = [NSHashTable weakObjectsHashTable];
        if (isName) cpCollabNames = views;
        else cpCollabPictures = views;
    }
    if (hide) [views addObject:view];
    else [views removeObject:view];
    privateAlpha(view, hide);
}
static void cpRestoreDisabledCollab(void) {
    if (!enabled(kReelNames)) {
        for (UIView *v in cpCollabNames.allObjects) privateAlpha(v, NO);
        [cpCollabNames removeAllObjects];
    }
    if (!enabled(kReelAvatars)) {
        for (UIView *v in cpCollabPictures.allObjects) privateAlpha(v, NO);
        [cpCollabPictures removeAllObjects];
    }
}
static void cpApplyReelCollaborators(UIView *author, NSArray<UIView *> *texts,
                                     UIView *primaryName, UIView *primaryPicture) {
    if (!enabled(kReelNames) && !enabled(kReelAvatars)) return;
    NSMutableOrderedSet<UIView *> *portraits = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<UIView *> *generic = [NSMutableOrderedSet orderedSet];
    if (primaryPicture && cpSmallReelPortrait(primaryPicture, author, NULL))
        [portraits addObject:primaryPicture];
    cpCollectCollabPortraits(author, author, portraits, generic, 0);
    NSMutableOrderedSet<UIView *> *names = [NSMutableOrderedSet orderedSet];
    if (primaryName) [names addObject:primaryName];

    // A combined-name label must be a single author-line label located beside
    // a known portrait (or the original selected author-name view).
    UIView *combined = nil;
    CGFloat best = CGFLOAT_MAX;
    for (UIView *text in texts) {
        if (!cpReelCombinedNames(cpString(text))) continue;
        CGRect r = [text convertRect:text.bounds toView:author];
        if (r.size.height < 8 || r.size.height > 58 || r.size.width < 22) continue;
        if (text == primaryName) { combined = text; break; }
        for (UIView *picture in portraits) {
            CGRect av = [picture convertRect:picture.bounds toView:author];
            if (!cpCollabNearPortrait(r, av)) continue;
            CGFloat score = fabs(CGRectGetMidY(r)-CGRectGetMidY(av)) +
                0.18*fabs(CGRectGetMinX(r)-CGRectGetMaxX(av));
            if (score < best) { best = score; combined = text; }
        }
    }
    if (combined) [names addObject:combined];

    NSString *rootName = lower(NSStringFromClass(author.class));
    BOOL collab = combined != nil || [rootName containsString:@"collab"] ||
                  [rootName containsString:@"coauthor"];
    // Recognize a split "and 2 others" label only when it is on the
    // same horizontal author row as the already identified username.
    if (!collab && primaryName) {
        CGRect line = [primaryName convertRect:primaryName.bounds toView:author];
        for (UIView *text in texts) {
            if (!cpReelCountSuffix(cpString(text))) continue;
            CGRect r = [text convertRect:text.bounds toView:author];
            CGFloat dx = CGRectGetMinX(r) - CGRectGetMaxX(line);
            CGFloat dy = fabs(CGRectGetMidY(r)-CGRectGetMidY(line));
            if (r.size.height >= 8 && r.size.height <= 58 &&
                dx >= -10 && dx <= 80 && dy <= MAX(8.0,line.size.height*0.6)) {
                collab = YES;
                break;
            }
        }
    }
    // Identify distinct, overlapping/adjacent portrait siblings (not the
    // nested image and its own wrapper) as evidence of a Collab layout.
    for (UIView *a in portraits) {
        for (UIView *b in portraits) {
            if (a == b || [a isDescendantOfView:b] || [b isDescendantOfView:a]) continue;
            CGRect ra = [a convertRect:a.bounds toView:author];
            CGRect rb = [b convertRect:b.bounds toView:author];
            CGFloat dx = fabs(CGRectGetMidX(ra)-CGRectGetMidX(rb));
            CGFloat dy = fabs(CGRectGetMidY(ra)-CGRectGetMidY(rb));
            if (dx <= 1 && dy <= 1) continue;
            if (dx <= MAX(ra.size.width, rb.size.width)*1.5 &&
                dy <= MAX(ra.size.height,rb.size.height)*0.8) collab = YES;
        }
    }

    if (collab) {
        UIView *line = combined ?: primaryName;
        CGRect lineRect = line ? [line convertRect:line.bounds toView:author] : CGRectNull;
        // Secondary avatars may be generic image views: include only those
        // overlapping the same left-hand avatar cluster, or immediately
        // left of the identified author-name line. Never hide music artwork.
        NSArray<UIView *> *anchors = portraits.array;
        for (UIView *image in generic) {
            CGRect ri = [image convertRect:image.bounds toView:author];
            BOOL matched = NO;
            if (line && cpCollabNearPortrait(lineRect, ri) &&
                CGRectGetMidX(ri) < CGRectGetMinX(lineRect) &&
                CGRectGetMinX(lineRect)-CGRectGetMaxX(ri) <= 65) matched = YES;
            for (UIView *anchor in anchors) {
                CGRect ra = [anchor convertRect:anchor.bounds toView:author];
                CGFloat dx = fabs(CGRectGetMidX(ra)-CGRectGetMidX(ri));
                CGFloat dy = fabs(CGRectGetMidY(ra)-CGRectGetMidY(ri));
                if (dx <= MAX(ra.size.width,ri.size.width)*1.6 &&
                    dy <= MAX(ra.size.height,ri.size.height)*0.85 &&
                    ri.size.width >= ra.size.width*0.40) matched = YES;
            }
            if (matched) [portraits addObject:image];
        }
        // Separate name labels are only accepted on the same author line
        // and near the existing confirmed name. Never use a full reel scan.
        if (line) {
            for (UIView *text in texts) {
                NSString *value = cpString(text);
                if (!cpReelAuthorText(value) && !cpReelCountSuffix(value)) continue;
                CGRect r = [text convertRect:text.bounds toView:author];
                if (r.size.height < 8 || r.size.height > 58) continue;
                CGFloat dy = fabs(CGRectGetMidY(r)-CGRectGetMidY(lineRect));
                if (dy > MAX(8.0,lineRect.size.height*0.6)) continue;
                if (CGRectGetMinX(r) < CGRectGetMinX(lineRect)-10 ||
                    CGRectGetMinX(r) > CGRectGetMaxX(lineRect)+150) continue;
                // Exclude standard action words even in localized layouts.
                NSString *l = lower(value);
                if ([@[@"follow", @"following", @"takip", @"takip et", @"seguir",
                        @"suivre", @"folgen", @"see more", @"more"] containsObject:l]) continue;
                [names addObject:text];
            }
        }
    }

    if (collab) {
        for (UIView *name in names) cpCollabAlpha(name, enabled(kReelNames), YES);
        UIView *line = combined ?: primaryName;
        CGRect lr = line ? [line convertRect:line.bounds toView:author] : CGRectNull;
        CGRect anchor = primaryPicture ?
            [primaryPicture convertRect:primaryPicture.bounds toView:author] : CGRectNull;
        for (UIView *picture in portraits) {
            CGRect pr = [picture convertRect:picture.bounds toView:author];
            BOOL nearLine = line && cpCollabNearPortrait(lr, pr) &&
                            CGRectGetMidX(pr) < CGRectGetMinX(lr) &&
                            CGRectGetMinX(lr)-CGRectGetMaxX(pr) <= 80;
            BOOL nearPrimary = primaryPicture &&
                fabs(CGRectGetMidX(pr)-CGRectGetMidX(anchor)) <= MAX(pr.size.width,anchor.size.width)*1.6 &&
                fabs(CGRectGetMidY(pr)-CGRectGetMidY(anchor)) <= MAX(pr.size.height,anchor.size.height);
            // Keep the whole avatar stack hidden, not unrelated artwork.
            if (picture == primaryPicture || nearLine || nearPrimary)
                cpCollabAlpha(picture, enabled(kReelAvatars), NO);
        }
    }
}

static void cpApplyReelAuthorChecked(UIView *author, BOOL confirmedByReelOverlay) {
    if (!author.window || (!confirmedByReelOverlay && !cpReelAuthorRoot(author))) return;
    NSString *cls = lower(NSStringFromClass(author.class));
    // Modern Instagram may render the avatar inside a user button but keep
    // the visible username as a SIBLING under the attribution wrapper.
    // Process the nested button AND the wrapper, instead of returning early.
    if ([cls containsString:@"userattribution"] ||
        [cls containsString:@"creatorattribution"] ||
        [cls containsString:@"authorattribution"] ||
        (confirmedByReelOverlay && cpReelSubView(author, @"userButton"))) {
        UIView *userButton = cpReelSubView(author, @"userButton");
        if (!userButton) userButton = cpReelSubView(author, @"authorButton");
        if (userButton && userButton != author) {
            cpApplyReelAuthorChecked(userButton, YES);
            // Do not return: a sibling username text view can live in author.
        }
    }
    UIView *nameView = nil;
    for (NSString *getter in @[@"userNameLabel", @"usernameLabel",
                               @"userNameView", @"usernameView",
                               @"userNameTextView", @"usernameTextView",
                               @"authorNameLabel", @"authorLabel",
                               @"nameLabel", @"nameTextView",
                               @"authorTextView"]) {
        UIView *candidate = cpReelSubView(author, getter);
        if (candidate && cpReelAuthorText(cpString(candidate))) {
            nameView = candidate;
            break;
        }
    }
    UIView *pictureView = nil;
    for (NSString *getter in @[@"profilePictureImageView", @"profilePictureView",
                               @"profilePicView", @"avatarImageView",
                               @"avatarView"]) {
        pictureView = cpReelSubView(author, getter);
        if (pictureView) break;
    }
    // Class-name fallback for newer Swift/Objective-C attribution variants.
    NSMutableArray<UIView *> *texts = [NSMutableArray array];
    NSMutableArray<UIView *> *pictures = [NSMutableArray array];
    cpGatherReel(author, texts, pictures, 0);
    NSString *modelName = cpReelModelName(author);
    if (!nameView && modelName) {
        for (UIView *view in texts) {
            if (cpReelNameMatches(view, modelName)) { nameView = view; break; }
        }
    }
    if (!nameView) {
        for (UIView *view in texts) {
            NSString *name = lower(NSStringFromClass(view.class));
            NSString *identifier = lower(view.accessibilityIdentifier);
            if (([name containsString:@"username"] ||
                 [name containsString:@"authorname"] ||
                 [identifier containsString:@"username"]) &&
                 cpReelAuthorText(cpString(view))) {
                nameView = view;
                break;
            }
        }
    }
    // Fallback: in the Reels attribution area, the separate author label
    // is normally positioned immediately to the RIGHT of the avatar.
    // Older Instagram used userNameLabel; newer builds often use a generic
    // UILabel/IGCoreTextView, whose class/identifier does not say "username".
    // Select it by geometry *within this author-only subtree*. This avoids
    // touching Follow, captions, music labels, like counts or timestamps.
    if (!nameView) {
        UIView *anchorPicture = pictureView;
        if (!anchorPicture) {
            // IGImageView itself has no "profilepicture" in its class name.
            // Recover the exact avatar through the nested native user button.
            UIView *userButton = cpReelSubView(author, @"userButton");
            if (!userButton) userButton = cpReelSubView(author, @"authorButton");
            if (userButton) {
                for (NSString *getter in @[@"profilePictureImageView",
                                           @"profilePictureView", @"avatarImageView",
                                           @"avatarView"]) {
                    anchorPicture = cpReelSubView(userButton, getter);
                    if (anchorPicture) break;
                }
            }
        }
        if (!anchorPicture) {
            for (UIView *candidate in pictures) {
                CGRect r = [candidate convertRect:candidate.bounds toView:author];
                CGFloat w = r.size.width, h = r.size.height;
                if (w >= 16 && w <= 96 && h >= 16 && h <= 96) {
                    anchorPicture = candidate;
                    break;
                }
            }
        }
        if (anchorPicture) {
            CGRect av = [anchorPicture convertRect:anchorPicture.bounds toView:author];
            CGFloat best = CGFLOAT_MAX;
            NSString *knownName = cpReelModelName(author);
            for (UIView *candidate in texts) {
                NSString *value = [cpString(candidate) stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (!cpReelAuthorText(value)) continue; // Follow / See more excluded
                CGRect r = [candidate convertRect:candidate.bounds toView:author];
                if (r.size.width < 18 || r.size.width > MAX(350.0, author.bounds.size.width) ||
                    r.size.height < 9 || r.size.height > 65) continue;
                CGFloat dx = CGRectGetMinX(r) - CGRectGetMaxX(av);
                CGFloat dy = fabs(CGRectGetMidY(r) - CGRectGetMidY(av));
                if (dx < -12 || dx > 210 || dy > 65) continue;
                CGFloat score = dy + 0.25 * fabs(dx - 12);
                if (knownName && cpReelNameMatches(candidate, knownName))
                    score -= 100;
                if (score < best) {
                    best = score;
                    nameView = candidate;
                }
            }
        }
    }
    // Only use a generic IGImageView as a fallback in a known user button,
    // not in the much broader reel overlay (which also holds music artwork).
    if (!pictureView && [cls containsString:@"userbutton"]) {
        for (UIView *view in author.subviews) {
            NSString *type = lower(NSStringFromClass(view.class));
            CGSize size = view.bounds.size;
            if (([type containsString:@"igimageview"] ||
                 [type containsString:@"profilepicture"] ||
                 [type containsString:@"avatar"]) &&
                size.width >= 16 && size.height >= 16 &&
                size.width <= 96 && size.height <= 96) {
                pictureView = view;
                break;
            }
        }
    }
    if (!pictureView) {
        for (UIView *view in pictures) {
            CGSize size = view.bounds.size;
            if (size.width >= 16 && size.height >= 16 &&
                size.width <= 96 && size.height <= 96) {
                pictureView = view;
                break;
            }
        }
    }
    if (nameView) privateAlpha(nameView, enabled(kReelNames));
    if (pictureView) privateAlpha(pictureView, enabled(kReelAvatars));
    cpApplyReelCollaborators(author, texts, nameView, pictureView);
}
static void cpApplyReelAuthor(UIView *author) {
    cpApplyReelAuthorChecked(author, NO);
}
static void cpApplyReelOverlay(UIView *overlay) {
    if (!overlay.window || !cpReelOverlayRoot(overlay)) return;
    // Modern overlays may expose a generic attribution UIView with a typed
    // userAttributionView property, but the avatar/username can be siblings
    // rather than both children of a historic IGSundialViewerUserButton.
    UIView *author = cpReelSubView(overlay, @"userAttributionView");
    if (!author) author = cpReelSubView(overlay, @"authorAttributionView");
    if (!author) author = cpReelSubView(overlay, @"creatorAttributionView");
    if (author) cpApplyReelAuthorChecked(author, YES);
}
static void cpRefreshReelFromText(UIView *text) {
    if (changingRenderedText || !enabled(kReelNames) || !text.window) return;
    for (UIView *parent = text.superview; parent; parent = parent.superview) {
        BOOL specificAuthor = cpReelAuthorRoot(parent);
        BOOL overlay = cpReelOverlayRoot(parent);
        if (specificAuthor || overlay) {
            __weak UIView *weakAuthor = parent;
            dispatch_async(dispatch_get_main_queue(), ^{
                UIView *author = weakAuthor;
                if (!author.window) return;
                if (specificAuthor) cpApplyReelAuthor(author);
                if (overlay) cpApplyReelOverlay(author);
            });
            break;
        }
    }
}


// Independent toggle for the small audio artwork / Original Audio entry
// point at the bottom of the RIGHT Reels action rail. Do not hide the
// left-hand song attribution, change playback, or hide arbitrary images.
static char kAudioAlpha, kAudioPending, kAudioSelection, kAudioLayerState, kAudioLayerSelection;
static NSHashTable<UIView *> *cpAudioHidden;
static NSHashTable<CALayer *> *cpAudioHiddenLayers;
static BOOL cpAudioViewerController(id object) {
    if (![object isKindOfClass:[UIViewController class]]) return NO;
    NSString *n=lower(NSStringFromClass([object class]));
    if ([n containsString:@"comment"] || [n containsString:@"editor"] ||
        [n containsString:@"capture"] || [n containsString:@"creation"] ||
        [n containsString:@"audio"] || [n containsString:@"profile"]) return NO;
    return [n containsString:@"sundialfeedviewcontroller"] ||
           [n containsString:@"sundialviewerviewcontroller"] ||
           [n containsString:@"reelsviewerviewcontroller"] ||
           [n containsString:@"clipsviewerviewcontroller"];
}
static BOOL cpAudioViewerCell(UIView *v) {
    NSString *n=lower(NSStringFromClass(v.class));
    return ([n containsString:@"sundialviewer"] || [n containsString:@"sundialfeed"] ||
            [n containsString:@"reelsviewer"] || [n containsString:@"clipsviewer"]) &&
           ([n containsString:@"videocell"] || [n containsString:@"reelcell"] ||
            [n containsString:@"feedcell"] || [n containsString:@"vieweritem"]);
}
static BOOL cpAudioRoot(UIView *v) {
    NSString *n = lower(NSStringFromClass(v.class));
    if (commentRow(v) || [n containsString:@"comment"] ||
        [n containsString:@"editor"] || [n containsString:@"creation"] ||
        [n containsString:@"capture"] || [n containsString:@"preview"]) return NO;
    if (cpReelOverlayRoot(v)) return YES;
    BOOL reel = [n containsString:@"sundial"] || [n containsString:@"reels"] ||
                [n containsString:@"clipsviewer"];
    BOOL controls = [n containsString:@"ufi"] || [n containsString:@"actionrail"] ||
                    [n containsString:@"actionbar"] || [n containsString:@"interactionbar"] ||
                    [n containsString:@"rightcontrols"] || [n containsString:@"controlsoverlay"];
    return (reel && controls) || cpAudioViewerCell(v) ||
           cpAudioViewerController(v.nextResponder);
}
// The artwork can be a sibling of the historical controls overlay. Prefer
// the enclosing native Reel cell, then its dedicated viewer controller.
static UIView *cpAudioScope(UIView *view) {
    UIView *root = nil;
    for (UIView *v = view; v && v != view.window; v = v.superview) {
        NSString *n = lower(NSStringFromClass(v.class));
        if ([n containsString:@"comment"] || [n containsString:@"editor"] ||
            [n containsString:@"capture"] || [n containsString:@"creation"]) break;
        if (cpAudioRoot(v)) root = v;
        if (cpAudioViewerCell(v)) return v;
        if ([v.nextResponder isKindOfClass:[UIViewController class]]) break;
    }
    return root;
}
static BOOL cpAudioNamed(UIView *v) {
    NSString *n = lower(NSStringFromClass(v.class));
    NSString *ident = lower(v.accessibilityIdentifier);
    NSString *label = lower(v.accessibilityLabel);
    NSString *s = [NSString stringWithFormat:@"%@ %@ %@",n,ident,label];
    for (NSString *bad in @[@"mute", @"volume", @"playback", @"playbutton",
                              @"pausebutton", @"savebutton", @"bookmark",
                              @"likebutton", @"commentbutton", @"sharebutton"])
        if ([s containsString:bad]) return NO;
    BOOL audio = [s containsString:@"audio"] || [s containsString:@"music"] ||
                 [s containsString:@"sound"] || [s containsString:@"albumart"];
    BOOL image = [s containsString:@"thumbnail"] || [s containsString:@"artwork"] ||
                 [s containsString:@"cover"] || [s containsString:@"album"] ||
                 [s containsString:@"attribution"] || [s containsString:@"button"] ||
                 [s containsString:@"entrypoint"] || [s containsString:@"pivot"];
    return (audio && image) || [label hasPrefix:@"original audio"] ||
           [label hasPrefix:@"original sound"] || [label hasPrefix:@"orijinal ses"] ||
           [label hasPrefix:@"view audio"] || [label hasPrefix:@"audio page"];
}
static BOOL cpAudioImageView(UIView *v) {
    NSString *n = lower(NSStringFromClass(v.class));
    return [v isKindOfClass:[UIImageView class]] || [n containsString:@"imageview"] ||
           [n containsString:@"artworkview"] || [n containsString:@"thumbnailview"];
}
static BOOL cpAudioBookmark(UIView *v) {
    NSString *n = lower(NSStringFromClass(v.class));
    NSString *i = lower(v.accessibilityIdentifier);
    NSString *l = lower(v.accessibilityLabel);
    return [n containsString:@"bookmark"] || [n containsString:@"savebutton"] ||
           [i containsString:@"bookmark"] || [i containsString:@"savebutton"] ||
           [i isEqualToString:@"save"] || [l isEqualToString:@"save"] ||
           [l isEqualToString:@"saved"] || [l isEqualToString:@"unsave"] ||
           [l hasPrefix:@"save reel"] || [l hasPrefix:@"remove from saved"] ||
           [l hasPrefix:@"save,"] || [l hasPrefix:@"save "] ||
           [l hasPrefix:@"saved,"] || [l hasPrefix:@"unsave "] ||
           [l hasPrefix:@"kaydet"] || [l isEqualToString:@"kaydedildi"];
}
static BOOL cpAudioRailRect(UIView *v, CGRect *outRect) {
    UIWindow *w = v.window;
    if (!w || !v.superview) return NO;
    CGRect r = [v convertRect:v.bounds toView:w];
    CGRect bounds = w.bounds;
    CGFloat width = r.size.width, height = r.size.height;
    if (width < 15 || height < 15 || width > 64 || height > 64 ||
        fabs(width-height) > MAX(width,height)*0.46) return NO;
    if (CGRectGetMidX(r) < CGRectGetMinX(bounds)+bounds.size.width*0.80 ||
        CGRectGetMidY(r) < CGRectGetMinY(bounds)+bounds.size.height*0.42 ||
        CGRectGetMidY(r) > CGRectGetMinY(bounds)+bounds.size.height*0.97)
        return NO;
    if (outRect) *outRect = r;
    return YES;
}
static UIView *cpAudioGetterView(UIView *parent, NSString *key) {
    SEL sel = NSSelectorFromString(key);
    NSMethodSignature *signature = [parent methodSignatureForSelector:sel];
    if (!signature || signature.numberOfArguments != 2 ||
        signature.methodReturnType[0] != '@') return nil;
    return cpReelSubView(parent,key);
}
static void cpAudioCollect(UIView *v, UIView *root,
                           NSMutableOrderedSet<UIView *> *named,
                           NSMutableOrderedSet<UIView *> *images,
                           NSMutableOrderedSet<UIView *> *bookmarks,
                           NSUInteger depth, NSUInteger *visited) {
    if (depth > 13 || *visited >= 600) return;
    (*visited)++;
    if (v != root) {
        NSString *n = lower(NSStringFromClass(v.class));
        if (cpReelAuthorRoot(v) || [n containsString:@"comment"] ||
            [n containsString:@"caption"] || [n containsString:@"socialcontext"])
            return;
        if (cpAudioRailRect(v,NULL)) {
            if (cpAudioNamed(v)) [named addObject:v];
            if (cpAudioImageView(v)) [images addObject:v];
            if (cpAudioBookmark(v)) [bookmarks addObject:v];
        }
    }
    if (v == root || cpAudioRoot(v)) {
        for (NSString *key in @[@"audioThumbnailButton", @"audioThumbnailView",
                                  @"audioThumbnailImageView", @"audioCoverButton",
                                  @"audioCoverView", @"audioArtworkView",
                                  @"albumArtView", @"musicThumbnailView",
                                  @"audioPageButton", @"audioPivotButton",
                                  @"audioAttributionButton", @"audioAttributionView",
                                  @"audioAttribution", @"audioButton", @"musicButton",
                                  @"musicAttributionView", @"audioEntryPoint"]) {
            UIView *candidate = cpAudioGetterView(v,key);
            if (candidate && candidate != root && cpAudioRailRect(candidate,NULL))
                [named addObject:candidate];
        }
        for (NSString *key in @[@"saveButton", @"bookmarkButton",
                                  @"saveControl", @"bookmarkControl"]) {
            UIView *candidate = cpAudioGetterView(v,key);
            if (candidate && cpAudioRailRect(candidate,NULL)) [bookmarks addObject:candidate];
        }
    }
    for (UIView *child in v.subviews)
        cpAudioCollect(child,root,named,images,bookmarks,depth+1,visited);
}
static void cpAudioAlpha(UIView *v, BOOL hide) {
    if (!v) return;
    NSNumber *prior = objc_getAssociatedObject(v,&kAudioAlpha);
    if (hide) {
        if (!cpAudioHidden) cpAudioHidden = [NSHashTable weakObjectsHashTable];
        [cpAudioHidden addObject:v];
        if (!prior) objc_setAssociatedObject(v,&kAudioAlpha,@(v.alpha),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (v.alpha != 0) v.alpha = 0;
    } else {
        if (prior) {
            objc_setAssociatedObject(v,&kAudioAlpha,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            v.alpha = prior.doubleValue;
        }
        [cpAudioHidden removeObject:v];
    }
}

// View hierarchies in newer versions may draw the artwork using a
// CALayer-backed generic UIView, not an UIImageView or audio-named button.
static BOOL cpAudioInWindow(UIView *v, UIView *root) {
    for (UIView *p=v; p; p=p.superview) {
        if (p.hidden || (p.alpha<0.01 && !objc_getAssociatedObject(p,&kAudioAlpha)))
            return NO;
        if (p==root) return YES;
    }
    return NO;
}
static BOOL cpAudioLayerRect(CALayer *layer, UIWindow *window, CGRect *outRect) {
    if (!layer.superlayer || !window) return NO;
    CGRect r=[layer convertRect:layer.bounds toLayer:window.layer];
    CGRect b=window.bounds;
    if (!isfinite(r.origin.x) || !isfinite(r.origin.y) ||
        r.size.width<18 || r.size.height<18 || r.size.width>48 || r.size.height>48 ||
        fabs(r.size.width-r.size.height)>MAX(r.size.width,r.size.height)*0.22 ||
        CGRectGetMidX(r)<b.size.width*0.87 ||
        CGRectGetMidY(r)<b.size.height*0.58 || CGRectGetMidY(r)>b.size.height*0.94)
        return NO;
    if (outRect) *outRect=r;
    return YES;
}
static BOOL cpAudioRounded(CALayer *layer) {
    return layer.cornerRadius>=2 && layer.cornerRadius<=MIN(layer.bounds.size.width,layer.bounds.size.height)*0.42;
}
static BOOL cpAudioHasPicture(CALayer *layer, NSUInteger depth) {
    if (depth>4) return NO;
    if (layer.contents) return YES;
    for (CALayer *child in layer.sublayers)
        if (cpAudioHasPicture(child,depth+1)) return YES;
    return NO;
}
static BOOL cpAudioArtworkView(UIView *v) {
    CGRect r;
    if (!cpAudioLayerRect(v.layer,v.window,&r) || cpAudioBookmark(v)) return NO;
    if ([v isKindOfClass:[UIImageView class]] &&
        ((UIImageView *)v).image.renderingMode==UIImageRenderingModeAlwaysTemplate) return NO;
    CALayer *l=v.layer;
    // A rounded square with a real picture (or an explicitly bordered
    // artwork wrapper) differs from ordinary unframed action glyphs.
    return (cpAudioRounded(l) && (cpAudioHasPicture(l,0) || l.borderWidth>=0.5)) ||
           (l.borderWidth>=0.5 && cpAudioHasPicture(l,0));
}
static void cpAudioCollectRail(UIView *v, UIView *root,
                               NSMutableArray<UIView *> *controls,
                               NSMutableArray<UIView *> *artwork,
                               NSUInteger depth, NSUInteger *visited) {
    if (depth>18 || (*visited)++>1800 || !cpAudioInWindow(v,root)) return;
    NSString *n=lower(NSStringFromClass(v.class));
    if (v!=root && (cpReelAuthorRoot(v) || [n containsString:@"comment"] ||
        [n containsString:@"caption"] || [n containsString:@"socialcontext"] ||
        (cpAudioViewerCell(v) && cpAudioScope(v)!=root))) return;
    CGRect r;
    if (v!=root && cpAudioRailRect(v,&r)) {
        BOOL button=[v isKindOfClass:[UIControl class]] ||
                    (v.accessibilityTraits & UIAccessibilityTraitButton) ||
                    [n containsString:@"button"] || cpAudioBookmark(v);
        if (button) [controls addObject:v];
        if (cpAudioArtworkView(v)) [artwork addObject:v];
    }
    for (UIView *child in v.subviews)
        cpAudioCollectRail(child,root,controls,artwork,depth+1,visited);
}
static BOOL cpAudioBelowRail(CGRect r, NSArray<UIView *> *controls) {
    CGFloat lastY=-1000;
    NSUInteger distinct=0;
    NSMutableArray<NSNumber *> *ys=[NSMutableArray array];
    for (UIView *c in controls) {
        CGRect b;
        if (!cpAudioRailRect(c,&b) || fabs(CGRectGetMidX(r)-CGRectGetMidX(b))>22) continue;
        CGFloat dy=CGRectGetMidY(r)-CGRectGetMidY(b);
        if (dy<24 || dy>420) continue;
        if (cpAudioBookmark(c) && dy<=125) return YES;
        [ys addObject:@(CGRectGetMidY(b))];
    }
    for (NSNumber *y in [ys sortedArrayUsingSelector:@selector(compare:)]) {
        if (y.doubleValue-lastY>23) { distinct++; lastY=y.doubleValue; }
    }
    return distinct>=2 && CGRectGetMidY(r)-lastY<=125;
}
static UIView *cpAudioFallbackView(UIView *root, NSArray<UIView *> **outControls) {
    NSMutableArray<UIView *> *controls=[NSMutableArray array];
    NSMutableArray<UIView *> *artwork=[NSMutableArray array];
    NSUInteger visited=0;
    cpAudioCollectRail(root,root,controls,artwork,0,&visited);
    if (outControls) *outControls=controls;
    UIView *best=nil;
    CGFloat score=-CGFLOAT_MAX;
    for (UIView *v in artwork) {
        CGRect r;
        if (!cpAudioLayerRect(v.layer,v.window,&r) || !cpAudioBelowRail(r,controls)) continue;
        CGFloat value=CGRectGetMidY(r)+(v.layer.borderWidth>=0.5?5:0);
        if (value>score) {score=value;best=v;}
    }
    return best;
}
static void cpAudioSetLayer(CALayer *layer, BOOL hide) {
    if (!layer) return;
    NSNumber *prior=objc_getAssociatedObject(layer,&kAudioLayerState);
    if (hide) {
        if (!cpAudioHiddenLayers) cpAudioHiddenLayers=[NSHashTable weakObjectsHashTable];
        [cpAudioHiddenLayers addObject:layer];
        if (!prior) objc_setAssociatedObject(layer,&kAudioLayerState,@(layer.hidden),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!layer.hidden) layer.hidden=YES;
    } else {
        if (prior) {
            objc_setAssociatedObject(layer,&kAudioLayerState,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            layer.hidden=prior.boolValue;
        }
        [cpAudioHiddenLayers removeObject:layer];
    }
}
static void cpAudioFindArtworkLayer(CALayer *layer, UIWindow *w,
                                    NSArray<UIView *> *controls, CALayer **best,
                                    CGFloat *bestScore, NSUInteger depth, NSUInteger *visited) {
    if (depth>23 || (*visited)++>3500 ||
        (layer.hidden && !objc_getAssociatedObject(layer,&kAudioLayerState))) return;
    CGRect r;
    // Standalone layer artwork can carry its own border and corner radius.
    // Only hide a bounded square below confirmed controls; never a video layer.
    if (cpAudioLayerRect(layer,w,&r) && cpAudioRounded(layer) &&
        layer.borderWidth>=0.5 && cpAudioHasPicture(layer,0) &&
        cpAudioBelowRail(r,controls)) {
        CGFloat score=CGRectGetMidY(r);
        if (score>*bestScore) { *bestScore=score; *best=layer; }
    }
    for (CALayer *child in layer.sublayers)
        cpAudioFindArtworkLayer(child,w,controls,best,bestScore,depth+1,visited);
}

static void cpRestoreDisabledAudio(void) {
    if (enabled(kReelAudio)) return;
    for (UIView *v in cpAudioHidden.allObjects) cpAudioAlpha(v,NO);
    for (CALayer *layer in cpAudioHiddenLayers.allObjects) cpAudioSetLayer(layer,NO);
}
// If the actual image lives in a small audio button, hide the entire
// button (including its outline), not the rest of the vertical action bar.
static UIView *cpAudioPromote(UIView *v, UIView *root) {
    UIView *p = v.superview;
    if (!p || p == root || cpAudioBookmark(p)) return v;
    CGRect a,b;
    if (!cpAudioRailRect(v,&a) || !cpAudioRailRect(p,&b)) return v;
    BOOL control = [p isKindOfClass:[UIControl class]] ||
                   (p.accessibilityTraits & UIAccessibilityTraitButton) ||
                   [lower(NSStringFromClass(p.class)) containsString:@"button"];
    if ((cpAudioNamed(p) || control) &&
        b.size.width <= a.size.width+20 && b.size.height <= a.size.height+20 &&
        fabs(CGRectGetMidX(a)-CGRectGetMidX(b)) <= 8 &&
        fabs(CGRectGetMidY(a)-CGRectGetMidY(b)) <= 8) return p;
    return v;
}
static void cpApplyReelAudio(UIView *root) {
    if (!root.window || !enabled(kReelAudio) || cpAudioScope(root) != root) return;
    NSMutableOrderedSet<UIView *> *named = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<UIView *> *images = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<UIView *> *bookmarks = [NSMutableOrderedSet orderedSet];
    NSUInteger visited=0;
    cpAudioCollect(root,root,named,images,bookmarks,0,&visited);
    UIView *chosen=nil;
    CGFloat best=-CGFLOAT_MAX;
    // The named or typed audio control is the most reliable candidate.
    for (UIView *v in named) {
        CGRect r;
        if (!cpAudioRailRect(v,&r) || cpAudioBookmark(v)) continue;
        CGFloat score=CGRectGetMidY(r);
        if (score>best) {best=score;chosen=v;}
    }
    // For modern generic artwork views, require the Save/Bookmark anchor
    // immediately above on the same right-hand rail. No global image scan.
    if (!chosen) {
        for (UIView *v in images) {
            CGRect r;
            if (!cpAudioRailRect(v,&r) || cpAudioBookmark(v)) continue;
            // A template UIImage is a glyph rather than actual cover art.
            if ([v isKindOfClass:[UIImageView class]]) {
                UIImage *image=((UIImageView *)v).image;
                if (image && image.renderingMode==UIImageRenderingModeAlwaysTemplate) continue;
            }
            for (UIView *save in bookmarks) {
                CGRect b;
                if (save==v || [v isDescendantOfView:save] ||
                    !cpAudioRailRect(save,&b)) continue;
                CGFloat dy=CGRectGetMidY(r)-CGRectGetMidY(b);
                CGFloat dx=fabs(CGRectGetMidX(r)-CGRectGetMidX(b));
                if (dx>22 || dy<MAX(22.0,b.size.height*0.6) || dy>120) continue;
                CGFloat score=CGRectGetMidY(r)-dx*2;
                if (score>best) {best=score;chosen=v;}
            }
        }
    }
    NSArray<UIView *> *railControls=nil;
    if (!chosen) chosen=cpAudioFallbackView(root,&railControls);
    CALayer *chosenLayer=nil;
    if (!chosen && railControls.count>=2) {
        CGFloat bestLayer=-CGFLOAT_MAX;
        NSUInteger layerVisited=0;
        cpAudioFindArtworkLayer(root.layer,root.window,railControls,&chosenLayer,&bestLayer,0,&layerVisited);
    }
    if (chosen) chosen=cpAudioPromote(chosen,root);
    NSHashTable<CALayer *> *oldLayers=objc_getAssociatedObject(root,&kAudioLayerSelection);
    for (CALayer *old in oldLayers.allObjects)
        if (old!=chosenLayer) cpAudioSetLayer(old,NO);
    if (!oldLayers && chosenLayer) {
        oldLayers=[NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(root,&kAudioLayerSelection,oldLayers,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [oldLayers removeAllObjects];
    if (chosenLayer) {
        [oldLayers addObject:chosenLayer];
        cpAudioSetLayer(chosenLayer,YES);
    }
    // Restore the old selection when a recycled reel changes its artwork
    // or when this layout no longer identifies the audio entry point.
    NSHashTable<UIView *> *previous=objc_getAssociatedObject(root,&kAudioSelection);
    for (UIView *old in previous.allObjects)
        if (old != chosen) cpAudioAlpha(old,NO);
    if (!previous) {
        previous=[NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(root,&kAudioSelection,previous,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [previous removeAllObjects];
    if (chosen) {
        [previous addObject:chosen];
        cpAudioAlpha(chosen,YES);
    }
}
static void cpScheduleReelAudio(UIView *view) {
    if (!enabled(kReelAudio) || !view.window) return;
    UIView *root=cpAudioScope(view);
    if (!root || objc_getAssociatedObject(root,&kAudioPending)) return;
    objc_setAssociatedObject(root,&kAudioPending,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakRoot=root;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongRoot=weakRoot;
        if (!strongRoot) return;
        objc_setAssociatedObject(strongRoot,&kAudioPending,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        cpApplyReelAudio(strongRoot);
    });
}


// Delayed original-audio portrait: modern Reels may insert it outside the
// old overlay subtree and animate its visibility after video playback starts.
// Confirm a visible Reels viewer in the window, then examine only a small
// right-rail artwork slot. No video pixels, usernames or network data read.
static char kTransientPortrait, kNativeSlotParent;
static NSHashTable<CALayer *> *cpTransientLayers;
static NSTimer *cpTransientTimer;
static BOOL cpTransientScanning;
static BOOL cpTransientQueued;
static CFTimeInterval cpTransientLastScan;
static BOOL cpTransientVisible(UIView *v, UIWindow *w) {
    if (!v || !w || (v!=w && v.window!=w)) return NO;
    for (UIView *p=v; p; p=p.superview) {
        BOOL owned=objc_getAssociatedObject(p.layer,&kTransientPortrait)!=nil;
        if ((p.hidden&&!owned) || (p.alpha<0.01 && !objc_getAssociatedObject(p,&kAudioAlpha))) return NO;
        if (p==w) return YES;
    }
    return NO;
}
static BOOL cpTransientReelEvidence(UIView *v, UIWindow *w) {
    if (!cpTransientVisible(v,w)) return NO;
    if (!(cpReelAuthorRoot(v)||cpAudioRoot(v)||cpAudioViewerCell(v))) return NO;
    CGRect r=[v convertRect:v.bounds toView:w];
    CGRect screen=w.bounds;
    if (!CGRectIntersectsRect(r,screen)) return NO;
    // Require the currently visible cell or the lower author/control area.
    // Offscreen preloaded cells must not activate the window fallback.
    return CGRectGetMidY(r)>CGRectGetMinY(screen)+screen.size.height*0.30 &&
           CGRectGetMidY(r)<CGRectGetMaxY(screen) &&
           r.size.width>40 && r.size.height>10;
}
static BOOL cpTransientSlot(CALayer *l, UIWindow *w, CGRect *outRect) {
    if (!l.superlayer || !w) return NO;
    CGRect r=[l convertRect:l.bounds toLayer:w.layer];
    CGRect b=w.bounds;
    CGFloat x=(CGRectGetMidX(r)-CGRectGetMinX(b))/b.size.width;
    CGFloat y=(CGRectGetMidY(r)-CGRectGetMinY(b))/b.size.height;
    if (!isfinite(x)||!isfinite(y)||x<0.87||x>0.985||y<0.67||y>0.94) return NO;
    CGFloat a=r.size.width,c=r.size.height;
    if (a<18||c<18||a>52||c>52||fabs(a-c)>MAX(a,c)*0.28) return NO;
    if (outRect) *outRect=r;
    return YES;
}
static BOOL cpTransientExcluded(UIView *v) {
    NSString *n=lower(NSStringFromClass(v.class));
    return [n containsString:@"comment"]||[n containsString:@"caption"]||
           [n containsString:@"editor"]||[n containsString:@"capture"]||
           [n containsString:@"tabbar"]||[n containsString:@"navigationbar"]||
           [n containsString:@"socialcontext"]||cpReelAuthorRoot(v);
}
static void cpTransientGather(UIView *v, UIWindow *w, NSMutableArray<UIView *> *controls,
                              NSMutableArray<UIView *> *candidates,
                              BOOL *reel,
                              NSUInteger depth, NSUInteger *visits) {
    if (depth>25||(*visits)++>4500||!cpTransientVisible(v,w)) return;
    if (cpTransientReelEvidence(v,w)) *reel=YES;
    if (cpTransientExcluded(v)) return;
    CGRect r;
    if (cpAudioRailRect(v,&r)) {
        NSString *n=lower(NSStringFromClass(v.class));
        BOOL control=[v isKindOfClass:[UIControl class]]||
                     (v.accessibilityTraits&UIAccessibilityTraitButton)||
                     [n containsString:@"button"]||cpAudioBookmark(v);
        // Generic image-backed glyphs also establish the vertical rail.
        if (control||cpAudioImageView(v)) [controls addObject:v];
        if (cpTransientSlot(v.layer,w,NULL)&&!cpAudioBookmark(v)) {
            BOOL rounded=cpAudioRounded(v.layer);
            BOOL border=v.layer.borderWidth>=0.5;
            BOOL picture=cpAudioHasPicture(v.layer,0);
            BOOL image=cpAudioImageView(v);
            BOOL templateImage=[v isKindOfClass:[UIImageView class]] &&
                ((UIImageView *)v).image.renderingMode==UIImageRenderingModeAlwaysTemplate;
            BOOL masked=v.layer.mask!=nil || v.layer.masksToBounds;
            if (cpAudioNamed(v)||(!templateImage&&
                ((rounded||border)&&(picture||image||border) ||
                 (masked&&picture&&image))))
                [candidates addObject:v];
        }
    }
    for (UIView *c in v.subviews) cpTransientGather(c,w,controls,candidates,reel,depth+1,visits);
}
static BOOL cpTransientBelow(CGRect r, NSArray<UIView *> *controls, UIWindow *w) {
    NSMutableArray<NSNumber *> *rows=[NSMutableArray array];
    for (UIView *v in controls) {
        CGRect b;
        if (!cpAudioRailRect(v,&b)) continue;
        CGFloat dx=fabs(CGRectGetMidX(r)-CGRectGetMidX(b));
        CGFloat dy=CGRectGetMidY(r)-CGRectGetMidY(b);
        if (dx>18||dy<27||dy>330) continue;
        if (cpAudioBookmark(v)&&dy<=110) return YES;
        [rows addObject:@(CGRectGetMidY(b))];
    }
    CGFloat last=-1000;
    NSUInteger distinct=0;
    for (NSNumber *y in [rows sortedArrayUsingSelector:@selector(compare:)]) {
        if (y.doubleValue-last>25) { distinct++;last=y.doubleValue; }
    }
    return distinct>=2 && CGRectGetMidY(r)-last<=110;
}
static void cpTransientFindLayers(CALayer *l, UIWindow *w, NSArray<UIView *> *controls,
                                  NSMutableArray<CALayer *> *matches,
                                  NSUInteger depth, NSUInteger *visits) {
    if (depth>29||(*visits)++>6500) return;
    if (l.hidden&&!objc_getAssociatedObject(l,&kTransientPortrait)) return;
    id delegate=l.delegate;
    if ([delegate isKindOfClass:[UIView class]]&&cpTransientExcluded(delegate)) return;
    CGRect r;
    if (cpTransientSlot(l,w,&r)&&cpAudioRounded(l)&&l.borderWidth>=0.5&&
        cpAudioHasPicture(l,0)&&cpTransientBelow(r,controls,w)) [matches addObject:l];
    for (CALayer *child in l.sublayers) cpTransientFindLayers(child,w,controls,matches,depth+1,visits);
}
static void cpTransientSet(CALayer *l, BOOL hide) {
    NSNumber *prior=objc_getAssociatedObject(l,&kTransientPortrait);
    if (hide) {
        if (!cpTransientLayers) cpTransientLayers=[NSHashTable weakObjectsHashTable];
        [cpTransientLayers addObject:l];
        if (!prior) objc_setAssociatedObject(l,&kTransientPortrait,@(l.hidden),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!l.hidden) {
            [CATransaction begin];[CATransaction setDisableActions:YES];
            ((void(*)(id,SEL,BOOL))originalTransientHidden)(l,@selector(setHidden:),YES);
            [CATransaction commit];
        }
    } else if (prior) {
        objc_setAssociatedObject(l,&kTransientPortrait,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [cpTransientLayers removeObject:l];
        [CATransaction begin];[CATransaction setDisableActions:YES];
        ((void(*)(id,SEL,BOOL))originalTransientHidden)(l,@selector(setHidden:),prior.boolValue);
        [CATransaction commit];
    }
}
static void cpTransientRestore(void) {
    for (CALayer *l in cpTransientLayers.allObjects) cpTransientSet(l,NO);
}

// Instagram 456 device report (440x956 pt):
// Counted UFI rows: (387.5,657,44,70), (387.5,730,44,70).
// Terminal Swift UFI: (389.5,798,40,48), same horizontal center.
// This terminal control remains present even when its picture is replaced
// by a 24pt glyph. Hide the SLOT, not only a rounded image after loading.
// Treat the class/geometry as a device-derived hypothesis; do not hide
// another UFI control solely because it shares the same Swift class.
static BOOL cpNativeRailRect(CALayer *l, UIWindow *w, CGRect *out) {
    CGRect r=[l convertRect:l.bounds toLayer:w.layer];
    CGRect b=w.bounds;
    CGFloat x=(CGRectGetMidX(r)-CGRectGetMinX(b))/b.size.width;
    CGFloat y=(CGRectGetMidY(r)-CGRectGetMinY(b))/b.size.height;
    if (!isfinite(x)||!isfinite(y)||x<0.84||x>0.985||y<0.40||y>0.94||
        r.size.width<12||r.size.width>90||r.size.height<12||r.size.height>125)
        return NO;
    if (out) *out=r;
    return YES;
}
static NSString *cpNativeOwner(CALayer *l) {
    id d=l.delegate;
    return d?NSStringFromClass([d class]):@"";
}
static BOOL cpNativeCounted(CALayer *l) {
    return [cpNativeOwner(l) hasSuffix:@"IGSundialUFIButtonWithCount"];
}
static BOOL cpNativeTerminal(CALayer *l, UIWindow *w) {
    NSString *n=cpNativeOwner(l);
    if (![n hasSuffix:@".IGSundialUFIButton"] &&
        ![n isEqualToString:@"IGSundialUFIButton"]) return NO;
    CGRect r;
    if (!cpNativeRailRect(l,w,&r)) return NO;
    CGFloat a=r.size.width,h=r.size.height;
    CGFloat y=(CGRectGetMidY(r)-CGRectGetMinY(w.bounds))/w.bounds.size.height;
    if (a<34||a>48||h<43||h>58||h-a<5||h-a>16||y<0.70||y>0.92) return NO;
    id d=l.delegate;
    // Never hide a control that explicitly identifies itself as Save or
    // another interaction. Some Swift wrappers have no accessibility label.
    if ([d isKindOfClass:[UIView class]]) {
        UIView *v=d;
        if (cpAudioBookmark(v)) return NO;
        NSString *label=lower(v.accessibilityLabel);
        NSString *ident=lower(v.accessibilityIdentifier);
        for (NSString *bad in @[@"like",@"comment",@"share",@"repost",@"send",@"more options",@"bookmark",@"save",@"beğen",@"yorum",@"paylaş",@"kaydet"])
            if ([label hasPrefix:bad]||[ident hasPrefix:bad]) return NO;
    }
    return YES;
}
static void cpNativeCollect(CALayer *l, UIWindow *w, NSMutableArray<CALayer *> *counted,
                            NSMutableArray<CALayer *> *terminal, NSUInteger depth, NSUInteger *visits) {
    if (depth>32||(*visits)++>9000) return;
    if (l.hidden&&!objc_getAssociatedObject(l,&kTransientPortrait)) return;
    if (l.opacity<0.01&&!objc_getAssociatedObject(l,&kTransientPortrait)) return;
    CGRect r;
    if (cpNativeRailRect(l,w,&r)) {
        if (cpNativeCounted(l)&&r.size.width>=30&&r.size.width<=60&&
            r.size.height>=50&&r.size.height<=90) [counted addObject:l];
        if (cpNativeTerminal(l,w)) [terminal addObject:l];
    }
    for (CALayer *child in l.sublayers) cpNativeCollect(child,w,counted,terminal,depth+1,visits);
}
static CALayer *cpNativeCommonRail(CALayer *a,CALayer *b,UIWindow *w) {
    for (CALayer *p=a.superlayer;p&&p!=w.layer;p=p.superlayer) {
        for (CALayer *q=b.superlayer;q&&q!=w.layer;q=q.superlayer) {
            if (q!=p) continue;
            CGRect r=[p convertRect:p.bounds toLayer:w.layer];
            if (r.size.width<=180&&r.size.height<=w.bounds.size.height) return p;
        }
    }
    return nil;
}
static NSArray<CALayer *> *cpNativeChoose(UIWindow *w) {
    NSMutableArray<CALayer *> *counted=[NSMutableArray array],*terminal=[NSMutableArray array];
    NSUInteger visits=0;
    cpNativeCollect(w.layer,w,counted,terminal,0,&visits);
    NSMutableArray<CALayer *> *matched=[NSMutableArray array];
    for (CALayer *candidate in terminal) {
        CGRect r; if (!cpNativeRailRect(candidate,w,&r)) continue;
        NSMutableArray<NSNumber *> *ys=[NSMutableArray array];
        BOOL near=NO;
        for (CALayer *row in counted) {
            CGRect b; if (!cpNativeRailRect(row,w,&b)) continue;
            CGFloat dy=CGRectGetMidY(r)-CGRectGetMidY(b);
            if (fabs(CGRectGetMidX(r)-CGRectGetMidX(b))>12||dy<28||dy>230) continue;
            // Matching classes and same column are already strong evidence.
            // Prefer shared rail ancestry; allow exact aligned adjacent rows
            // even when Swift hosts each button separately.
            CGFloat gap=CGRectGetMinY(r)-CGRectGetMaxY(b);
            if (gap>=-8&&gap<=32&&(cpNativeCommonRail(candidate,row,w)||
                fabs(CGRectGetMidX(r)-CGRectGetMidX(b))<=3)) near=YES;
            [ys addObject:@(CGRectGetMidY(b))];
        }
        NSUInteger distinct=0;CGFloat last=-1000;
        for (NSNumber *y in [ys sortedArrayUsingSelector:@selector(compare:)]) {
            if (y.doubleValue-last>30) {distinct++;last=y.doubleValue;}
        }
        if (near&&distinct>=2) [matched addObject:candidate];
    }
    return matched;
}
static BOOL cpNativeDescendant(CALayer *layer,CALayer *ancestor) {
    for (CALayer *p=layer;p;p=p.superlayer) if (p==ancestor) return YES;
    return NO;
}
// An animated portrait may be attached as a sibling instead of a child of
// the terminal control. Only take a compact artwork layer in that same slot.
static void cpNativeSlotArtwork(CALayer *l, UIWindow *w, CALayer *button, CGRect slot,
                                NSMutableSet<CALayer *> *targets, NSUInteger depth, NSUInteger *visits) {
    if (depth>30||(*visits)++>8500||cpNativeDescendant(l,button)) return;
    if (l.hidden&&!objc_getAssociatedObject(l,&kTransientPortrait)) return;
    NSString *owner=cpNativeOwner(l);
    if ([owner containsString:@"TabBar"]||[owner containsString:@"Comment"]||
        [owner containsString:@"Caption"]) return;
    CGRect r;
    if (cpNativeRailRect(l,w,&r)&&r.size.width>=18&&r.size.width<=62&&
        r.size.height>=18&&r.size.height<=62&&
        fabs(CGRectGetMidX(r)-CGRectGetMidX(slot))<=10&&
        fabs(CGRectGetMidY(r)-CGRectGetMidY(slot))<=13&&
        !cpNativeDescendant(button,l)&&
        ![owner containsString:@"Label"]&&
        (cpAudioRounded(l)||l.borderWidth>=0.5||l.mask!=nil)&&
        (cpAudioHasPicture(l,0)||l.borderWidth>=0.5)) {
        [targets addObject:l];
        return;
    }
    for (CALayer *child in l.sublayers) cpNativeSlotArtwork(child,w,button,slot,targets,depth+1,visits);
}

static void cpTransientSchedule(void);

// The Swift UFI is reused across reels. Identify the terminal control in
// local rail coordinates before a scroll moves it into the window viewport.
// Never identify a 44x44 interaction button just by its class.
static BOOL cpNativeLocalIdentity(CALayer *l) {
    NSString *n=cpNativeOwner(l);
    if (![n hasSuffix:@".IGSundialUFIButton"] &&
        ![n isEqualToString:@"IGSundialUFIButton"]) return NO;
    CGSize z=l.bounds.size;
    if (z.width<34||z.width>48||z.height<43||z.height>58||
        z.height-z.width<5||z.height-z.width>16) return NO;
    id d=l.delegate;
    if (![d isKindOfClass:[UIView class]]) return NO;
    UIView *v=d;
    if (cpAudioBookmark(v)) return NO;
    NSString *label=lower(v.accessibilityLabel),*ident=lower(v.accessibilityIdentifier);
    for (NSString *bad in @[@"like",@"comment",@"share",@"repost",@"send",@"more options",
                              @"bookmark",@"save",@"beğen",@"yorum",@"paylaş",@"kaydet"])
        if ([label hasPrefix:bad]||[ident hasPrefix:bad]) return NO;
    return YES;
}
static void cpNativeLocalRows(CALayer *l,CALayer *root,CALayer *candidate,CGRect target,
                              NSMutableArray<NSNumber *> *rows,BOOL *near,
                              NSUInteger depth,NSUInteger *visits) {
    if (depth>10||(*visits)++>550||l==candidate) return;
    if (cpNativeCounted(l)) {
        CGRect b=[l convertRect:l.bounds toLayer:root];
        CGFloat dx=fabs(CGRectGetMidX(target)-CGRectGetMidX(b));
        CGFloat dy=CGRectGetMidY(target)-CGRectGetMidY(b);
        CGFloat gap=CGRectGetMinY(target)-CGRectGetMaxY(b);
        if (b.size.width>=30&&b.size.width<=60&&b.size.height>=50&&b.size.height<=90&&
            dx<=12&&dy>=28&&dy<=230) {
            [rows addObject:@(CGRectGetMidY(b))];
            if (gap>=-8&&gap<=32&&dx<=5) *near=YES;
        }
        return;
    }
    for (CALayer *child in l.sublayers)
        cpNativeLocalRows(child,root,candidate,target,rows,near,depth+1,visits);
}
static BOOL cpNativeLocalConfirmed(CALayer *l) {
    if (!l.superlayer||!cpNativeLocalIdentity(l)) return NO;
    for (CALayer *p=l.superlayer; p; p=p.superlayer) {
        if ([p.delegate isKindOfClass:[UIWindow class]]) break;
        // A shared compact rail can be evaluated even while offscreen.
        if (p.bounds.size.width>10&&p.bounds.size.width<=180&&p.bounds.size.height>45) {
            CGRect r=[l convertRect:l.bounds toLayer:p];
            NSMutableArray<NSNumber *> *rows=[NSMutableArray array];
            BOOL near=NO;NSUInteger visits=0;
            cpNativeLocalRows(p,p,l,r,rows,&near,0,&visits);
            NSUInteger distinct=0;CGFloat last=-1000;
            for (NSNumber *y in [rows sortedArrayUsingSelector:@selector(compare:)]) {
                if (y.doubleValue-last>30) {distinct++;last=y.doubleValue;}
            }
            // A single counted row in the same narrow rail is sufficient
            // for the exact 40x48 native slot when another count is absent.
            if (near&&(distinct>=2||(distinct==1&&fabs(l.bounds.size.width-40)<=1&&
                fabs(l.bounds.size.height-48)<=1))) return YES;
        }
        if (p.bounds.size.width>220) break;
    }
    return NO;
}
static BOOL cpNativeRetained(CALayer *l) {
    NSHashTable<CALayer *> *parent=objc_getAssociatedObject(l,&kNativeSlotParent);
    return l.superlayer&&[parent containsObject:l.superlayer]&&cpNativeLocalIdentity(l);
}
static void cpNativeRemember(CALayer *l) {
    if (!l.superlayer) return;
    NSHashTable<CALayer *> *parent=[NSHashTable weakObjectsHashTable];
    [parent addObject:l.superlayer];
    objc_setAssociatedObject(l,&kNativeSlotParent,parent,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void cpNativeForget(CALayer *l) {
    objc_setAssociatedObject(l,&kNativeSlotParent,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL cpNativePrehide(CALayer *l) {
    if (!enabled(kReelAudio)||![NSThread isMainThread]||!l) return NO;
    if (cpNativeRetained(l)||cpNativeLocalConfirmed(l)) {
        cpNativeRemember(l);
        cpTransientSet(l,YES);
        return YES;
    }
    // A recycled control that no longer has the same identity or parent
    // must not retain privacy state from its previous reel.
    if (objc_getAssociatedObject(l,&kNativeSlotParent)) {
        cpNativeForget(l);
        cpTransientSet(l,NO);
    }
    return NO;
}
static void cpNativePrehideAncestor(CALayer *l) {
    if (!l||!enabled(kReelAudio)||![NSThread isMainThread]) return;
    for (NSUInteger i=0;l&&i<8;i++,l=l.superlayer) {
        if (cpNativeLocalIdentity(l)) {cpNativePrehide(l);return;}
    }
}
static void cpNativeViewLayout(UIView *self,SEL cmd) {
    ((void(*)(id,SEL))originalNativeLayout)(self,cmd);
    if (enabled(kReelAudio)) {cpNativePrehide(self.layer);cpTransientSchedule();}
}
static void cpNativeViewMove(UIView *self,SEL cmd) {
    ((void(*)(id,SEL))originalNativeMove)(self,cmd);
    if (enabled(kReelAudio)) {cpNativePrehide(self.layer);cpTransientSchedule();}
}
static void cpNativeViewSuperview(UIView *self,SEL cmd) {
    ((void(*)(id,SEL))originalNativeSuperview)(self,cmd);
    if (enabled(kReelAudio)) {cpNativePrehide(self.layer);cpTransientSchedule();}
}
static void cpNativeViewBounds(UIView *self,SEL cmd,CGRect r) {
    ((void(*)(id,SEL,CGRect))originalNativeBounds)(self,cmd,r);
    if (enabled(kReelAudio)) cpNativePrehide(self.layer);
}
static void cpNativeViewFrame(UIView *self,SEL cmd,CGRect r) {
    ((void(*)(id,SEL,CGRect))originalNativeFrame)(self,cmd,r);
    if (enabled(kReelAudio)) cpNativePrehide(self.layer);
}

static void cpTransientScan(void) {
    if (!enabled(kReelAudio)||cpTransientScanning||![NSThread isMainThread]) return;
    if ([UIApplication sharedApplication].applicationState!=UIApplicationStateActive) return;
    CFTimeInterval now=CACurrentMediaTime();
    if (now-cpTransientLastScan<0.055) return;
    cpTransientLastScan=now;
    cpTransientScanning=YES;
    @try {
        NSMutableSet<CALayer *> *targets=[NSMutableSet set];
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.isKeyWindow||w.hidden||w.alpha<0.01) continue;
            NSArray<CALayer *> *nativeSlots=cpNativeChoose(w);
            for (CALayer *native in nativeSlots) {
                CGRect r;
                if (!cpNativeRailRect(native,w,&r)) continue;
                cpNativeRemember(native);
                [targets addObject:native];
                NSUInteger slotVisits=0;
                cpNativeSlotArtwork(w.layer,w,native,r,targets,0,&slotVisits);
            }
            if (nativeSlots.count) continue;
            NSMutableArray<UIView *> *controls=[NSMutableArray array];
            NSMutableArray<UIView *> *candidates=[NSMutableArray array];
            BOOL reel=NO;NSUInteger visits=0;
            cpTransientGather(w,w,controls,candidates,&reel,0,&visits);
            if (!reel) continue;
            NSMutableArray<CALayer *> *matches=[NSMutableArray array];
            for (UIView *v in candidates) {
                CGRect r;
                if (!cpTransientSlot(v.layer,w,&r)||!cpTransientBelow(r,controls,w)) continue;
                [matches addObject:v.layer];
                UIView *p=v.superview;
                CGRect b;
                if (p&&!cpAudioBookmark(p)&&cpTransientSlot(p.layer,w,&b)&&
                    fabs(CGRectGetMidX(b)-CGRectGetMidX(r))<7&&
                    fabs(CGRectGetMidY(b)-CGRectGetMidY(r))<7&&
                    (cpAudioRounded(p.layer)||p.layer.borderWidth>=0.5))
                    [matches addObject:p.layer];
            }
            NSUInteger layerVisits=0;
            cpTransientFindLayers(w.layer,w,controls,matches,0,&layerVisits);
            // Choose one artwork position, not all images in the rail.
            // Include overlapping wrappers at that exact slot, for borders.
            CALayer *best=nil; CGFloat bestY=-CGFLOAT_MAX;CGRect bestRect=CGRectNull;
            for (CALayer *l in matches) {
                CGRect r;
                if (cpTransientSlot(l,w,&r)&&CGRectGetMidY(r)>bestY) {
                    best=l;bestY=CGRectGetMidY(r);bestRect=r;
                }
            }
            if (best) {
                for (CALayer *l in matches) {
                    CGRect r;
                    if (cpTransientSlot(l,w,&r)&&
                        fabs(CGRectGetMidY(r)-CGRectGetMidY(bestRect))<9&&
                        fabs(CGRectGetMidX(r)-CGRectGetMidX(bestRect))<9)
                        [targets addObject:l];
                }
            }
        }
        for (CALayer *l in cpTransientLayers.allObjects) {
            if ([targets containsObject:l]) continue;
            // Do not restore a confirmed native slot just because its reel
            // is between pages, offscreen or missing from one scan.
            if (cpNativeRetained(l)) {cpTransientSet(l,YES);continue;}
            cpNativeForget(l);
            cpTransientSet(l,NO);
        }
        for (CALayer *l in targets) cpTransientSet(l,YES);
    } @finally {cpTransientScanning=NO;}
}
static void cpTransientSchedule(void) {
    if (!enabled(kReelAudio)||cpTransientQueued||cpTransientScanning) return;
    cpTransientQueued=YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        cpTransientQueued=NO;cpTransientScan();
    });
}
static void cpTransientUpdateTimer(void) {
    if (!enabled(kReelAudio)) {
        [cpTransientTimer invalidate];cpTransientTimer=nil;
        for (CALayer *l in cpTransientLayers.allObjects) cpNativeForget(l);
        cpTransientRestore();return;
    }
    if (!cpTransientTimer) {
        cpTransientTimer=[NSTimer timerWithTimeInterval:0.20 repeats:YES block:^(NSTimer *t) {
            if (!enabled(kReelAudio)) {cpTransientUpdateTimer();return;}
            cpTransientScan();
        }];
        [[NSRunLoop mainRunLoop] addTimer:cpTransientTimer forMode:NSRunLoopCommonModes];
    }
    cpTransientSchedule();
}
static void cpTransientLayerHidden(CALayer *self,SEL cmd,BOOL value) {
    if (!value && [NSThread isMainThread] && enabled(kReelAudio) && !cpTransientScanning)
        cpNativePrehideAncestor(self);
    NSNumber *prior=objc_getAssociatedObject(self,&kTransientPortrait);
    if (prior&&enabled(kReelAudio)) {
        // Keep the latest app-requested value for clean toggle-off restore.
        if (!cpTransientScanning)
            objc_setAssociatedObject(self,&kTransientPortrait,@(value),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        value=YES;
    }
    ((void(*)(id,SEL,BOOL))originalTransientHidden)(self,cmd,value);
}
static void cpTransientLayerContents(CALayer *self,SEL cmd,id value) {
    ((void(*)(id,SEL,id))originalTransientContents)(self,cmd,value);
    if (![NSThread isMainThread]||!enabled(kReelAudio)||cpTransientScanning) return;
    CGSize size=self.bounds.size;
    if (size.width>=16&&size.width<=65&&size.height>=16&&size.height<=65) {
        cpNativePrehideAncestor(self);
        cpTransientSchedule();
    }
}
static void cpTransientLayerAnimation(CALayer *self,SEL cmd,CAAnimation *animation,NSString *key) {
    if ([NSThread isMainThread]&&enabled(kReelAudio)&&!cpTransientScanning) {
        CGSize size=self.bounds.size;
        if (size.width>=16&&size.width<=65&&size.height>=16&&size.height<=65) {
            cpNativePrehideAncestor(self);
            cpTransientSchedule();
        }
    }
    ((void(*)(id,SEL,id,id))originalTransientAnimation)(self,cmd,animation,key);
}

static void walk(UIView *v, NSUInteger depth) {
    if (depth > 25) return;
    if (commentRow(v)) applyRow(v);
    if (cpReelAuthorRoot(v)) cpApplyReelAuthor(v);
    if (cpReelOverlayRoot(v)) cpApplyReelOverlay(v);
    if (enabled(kReelAudio) && cpAudioRoot(v)) cpApplyReelAudio(v);
    for (UIView *c in v.subviews) walk(c, depth + 1);
}
static void refresh(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        cpRestoreDisabledCollab();
        cpRestoreDisabledAudio();
        cpTransientUpdateTimer();
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
    footer.text = @"Reels options hide the author's name, profile picture and right-hand audio thumbnail independently. Audio playback is unchanged.";
    footer.textColor = [UIColor secondaryLabelColor];
    footer.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    footer.textAlignment = NSTextAlignmentCenter;
    footer.numberOfLines = 0;
    self.tableView.tableFooterView = footer;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 2 : 3;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Comments" : @"Reels";
}
- (UITableViewCell *)tableView:(UITableView *)tableView
        cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"privacy"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"privacy"];
    NSString *key = nil;
    NSString *title = nil;
    if (indexPath.section == 0) {
        key = indexPath.row == 0 ? kNames : kAvatars;
        title = indexPath.row == 0 ? @"Hide Comment Usernames" : @"Hide Comment Avatars";
    } else if (indexPath.row == 2) {
        key = kReelAudio;
        title = @"Hide Reels Audio Thumbnail";
    } else {
        key = indexPath.row == 0 ? kReelNames : kReelAvatars;
        title = indexPath.row == 0 ? @"Hide Reels Usernames" : @"Hide Reels Profile Pictures";
    }
    cell.textLabel.text = title;
    cell.textLabel.adjustsFontSizeToFitWidth = YES;
    cell.textLabel.minimumScaleFactor = 0.8;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.accessibilityIdentifier = key;
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
static void cpAttachCommentControl(UIView *v, BOOL confirmed) {
    if (!v || !v.window || objc_getAssociatedObject(v,&kGesture) ||
        (!confirmed && !commentButton(v))) return;
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[CPAction shared] action:@selector(open:)];
    press.minimumPressDuration = 0.55;
    press.cancelsTouchesInView = YES;
    [v addGestureRecognizer:press];
    objc_setAssociatedObject(v, &kGesture, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void attach(UIView *v) {
    cpAttachCommentControl(v,NO);
    if (!v.window || (!cpAudioScope(v) && !cpAudioScope(v.superview))) return;
    // Native Reels UFI can use a generic control with no button title.
    if (cpAudioRoot(v)) {
        for (NSString *key in @[@"commentButton",@"commentsButton",@"commentControl",
                                 @"commentCountBouncyButton",@"commentCountButton",
                                 @"commentActionButton",@"commentActionView"]) {
            UIView *control=cpAudioGetterView(v,key);
            if (control && control!=v) cpAttachCommentControl(control,YES);
        }
    }
    NSString *n=lower(NSStringFromClass(v.class));
    NSString *i=lower(v.accessibilityIdentifier);
    NSString *l=lower(v.accessibilityLabel);
    BOOL exact=[n containsString:@"commentbutton"]||[n containsString:@"commentcontrol"]||
        [i containsString:@"comment_button"]||[i containsString:@"commentbutton"]||
        [i containsString:@"comment_action"]||[i containsString:@"comments_button"]||
        [l hasPrefix:@"comments,"]||[l hasPrefix:@"comment,"]||
        [l hasPrefix:@"view comments"]||[l hasPrefix:@"yorumları gör"];
    if (exact && cpAudioRailRect(v,NULL)) cpAttachCommentControl(v,YES);
}
// Independent fallback: hold TWO fingers still anywhere on the Instagram
// window. This works even when the Reels comment control is not a UIView.
static char kWindowPrivacyGesture;
static void cpInstallWindowPrivacyGesture(UIWindow *w) {
    if (!w || objc_getAssociatedObject(w,&kWindowPrivacyGesture)) return;
    UILongPressGestureRecognizer *press=[[UILongPressGestureRecognizer alloc]
        initWithTarget:[CPAction shared] action:@selector(open:)];
    press.numberOfTouchesRequired=2;
    press.minimumPressDuration=0.65;
    press.allowableMovement=12;
    press.cancelsTouchesInView=NO;
    press.delaysTouchesBegan=NO;
    [w addGestureRecognizer:press];
    objc_setAssociatedObject(w,&kWindowPrivacyGesture,press,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void didMove(UIView *self, SEL cmd) {
    ((void (*)(id, SEL))originalMove)(self, cmd);
    if (objc_getAssociatedObject(self,&kAudioAlpha) &&
        (!self.window || !cpAudioScope(self) || !enabled(kReelAudio))) cpAudioAlpha(self,NO);
    if (!self.window) return;
    cpInstallWindowPrivacyGesture(self.window);
    attach(self);
    if (enabled(kReelAudio) && (cpAudioRoot(self) || cpAudioNamed(self) ||
                               cpAudioImageView(self) || cpAudioBookmark(self))) {
        cpScheduleReelAudio(self);
        cpTransientSchedule();
    }
    BOOL comments = commentRow(self);
    BOOL reelAuthor = cpReelAuthorRoot(self);
    BOOL reelOverlay = cpReelOverlayRoot(self);
    if (comments || reelAuthor || reelOverlay) {
        __weak UIView *weak = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *view = weak;
            if (!view.window) return;
            if (comments) applyRow(view);
            if (reelAuthor) cpApplyReelAuthor(view);
            if (reelOverlay) cpApplyReelOverlay(view);
        });
    }
}
static void setLabel(UIView *self, SEL cmd, NSString *label) {
    ((void (*)(id, SEL, id))originalSetLabel)(self, cmd, label);
    if (self.window) {
        attach(self);
        if (enabled(kReelAudio) && (cpAudioNamed(self) || cpAudioBookmark(self)))
            cpScheduleReelAudio(self);
    }
}
static void setIdentifier(UIView *self, SEL cmd, NSString *value) {
    ((void (*)(id, SEL, id))originalSetIdentifier)(self, cmd, value);
    if (self.window) {
        attach(self);
        if (enabled(kReelAudio) && (cpAudioNamed(self) || cpAudioBookmark(self)))
            cpScheduleReelAudio(self);
    }
}
static void genericLayout(UIView *self, SEL cmd) {
    ((void (*)(id, SEL))originalAnyLayout)(self, cmd);
    if (changingRenderedText || !self.window) return;
    if (cpAudioRoot(self)) attach(self);
    if (commentRow(self)) applyRow(self);
    if (cpReelAuthorRoot(self)) cpApplyReelAuthor(self);
    if (cpReelOverlayRoot(self)) cpApplyReelOverlay(self);
    if (enabled(kReelAudio)) {
        if (cpAudioRoot(self)) cpApplyReelAudio(self);
        else if (objc_getAssociatedObject(self,&kAudioAlpha) || cpAudioNamed(self) ||
                 (cpAudioRailRect(self,NULL) && cpAudioArtworkView(self)))
            cpScheduleReelAudio(self);
    }
}
static void audioControllerLayout(UIViewController *self, SEL cmd) {
    ((void (*)(id, SEL))originalAudioControllerLayout)(self,cmd);
    if (enabled(kReelAudio) && cpAudioViewerController(self) && self.isViewLoaded)
        cpScheduleReelAudio(self.view);
}
static void audioImage(UIImageView *self, SEL cmd, UIImage *image) {
    ((void (*)(id, SEL, id))originalAudioImage)(self,cmd,image);
    if (enabled(kReelAudio) && [NSThread isMainThread] && cpAudioRailRect(self,NULL))
        cpScheduleReelAudio(self);
}
static void refreshFromLabel(UILabel *label) {
    if (changingRenderedText || !label.window) return;
    cpRefreshReelFromText(label);
    if (!enabled(kNames)) return;
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
            swapMethod([CALayer class], @selector(setHidden:),
                       (IMP)cpTransientLayerHidden,&originalTransientHidden);
            swapMethod([CALayer class], @selector(setContents:),
                       (IMP)cpTransientLayerContents,&originalTransientContents);
            swapMethod([CALayer class], @selector(addAnimation:forKey:),
                       (IMP)cpTransientLayerAnimation,&originalTransientAnimation);
            swapMethod([UIView class], @selector(didMoveToWindow),
                       (IMP)didMove, &originalMove);
            swapMethod([UIView class], @selector(layoutSubviews),
                       (IMP)genericLayout, &originalAnyLayout);
            swapMethod([UIViewController class], @selector(viewDidLayoutSubviews),
                       (IMP)audioControllerLayout, &originalAudioControllerLayout);
            swapMethod([UIImageView class], @selector(setImage:),
                       (IMP)audioImage, &originalAudioImage);
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
            Class nativeUFI=NSClassFromString(@"IGSundialCommonUISwiftShared.IGSundialUFIButton");
            if (nativeUFI && [nativeUFI isSubclassOfClass:[UIView class]]) {
                swapMethod(nativeUFI,@selector(layoutSubviews),(IMP)cpNativeViewLayout,&originalNativeLayout);
                swapMethod(nativeUFI,@selector(didMoveToWindow),(IMP)cpNativeViewMove,&originalNativeMove);
                swapMethod(nativeUFI,@selector(didMoveToSuperview),(IMP)cpNativeViewSuperview,&originalNativeSuperview);
                swapMethod(nativeUFI,@selector(setBounds:),(IMP)cpNativeViewBounds,&originalNativeBounds);
                swapMethod(nativeUFI,@selector(setFrame:),(IMP)cpNativeViewFrame,&originalNativeFrame);
            }
            for (UIWindow *w in [UIApplication sharedApplication].windows)
                cpInstallWindowPrivacyGesture(w);
            cpTransientUpdateTimer();
        });
    }
}
