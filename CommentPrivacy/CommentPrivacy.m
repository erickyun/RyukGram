#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Independent experimental Instagram tweak. RyukGram itself is not modified.
static NSString *const kNames = @"CPHideCommentUsernames";
static NSString *const kAvatars = @"CPHideCommentAvatars";
static NSString *const kReelNames = @"CPHideReelUsernames";
static NSString *const kReelAvatars = @"CPHideReelProfilePictures";
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
           [n containsString:@"creatorheader"];
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
        if (candidate && username(cpString(candidate))) {
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
                 username(cpString(view))) {
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
                if (!username(value)) continue; // Follow / See more excluded
                CGRect r = [candidate convertRect:candidate.bounds toView:author];
                if (r.size.width < 18 || r.size.width > 350 ||
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

static void walk(UIView *v, NSUInteger depth) {
    if (depth > 25) return;
    if (commentRow(v)) applyRow(v);
    if (cpReelAuthorRoot(v)) cpApplyReelAuthor(v);
    if (cpReelOverlayRoot(v)) cpApplyReelOverlay(v);
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
    footer.text = @"Comment options affect post and Reels comments. Reels options affect the video author's username and profile picture only.";
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
    return 2;
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
    if (self.window) attach(self);
}
static void setIdentifier(UIView *self, SEL cmd, NSString *value) {
    ((void (*)(id, SEL, id))originalSetIdentifier)(self, cmd, value);
    if (self.window) attach(self);
}
static void genericLayout(UIView *self, SEL cmd) {
    ((void (*)(id, SEL))originalAnyLayout)(self, cmd);
    if (changingRenderedText || !self.window) return;
    if (commentRow(self)) applyRow(self);
    if (cpReelAuthorRoot(self)) cpApplyReelAuthor(self);
    if (cpReelOverlayRoot(self)) cpApplyReelOverlay(self);
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
            NSLog(@"[CommentPrivacy] loaded; four independent toggles default OFF");
        });
    }
}
