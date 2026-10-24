# Comment Privacy (experimental)

A separate iOS Objective-C dynamic library for the RyukGram-patched Instagram IPA. It does **not** replace RyukGram's own dylib, bundle, or settings.

## What it is designed to do

- Long-press a **Comment** button for 0.55 seconds to open **Comment Privacy**.
- Toggle **Hide Comment Usernames** and **Hide Comment Avatars** independently.
- Both switches default to OFF and persist in local app preferences.
- Hide only detected comment author labels and avatar views; retain comments, likes, dates and replies.
- Restore the view's original alpha when the corresponding setting is disabled.

## Build and inject

1. In this fork's **Actions**, select **Build and inject Comment Privacy**.
2. Press **Run workflow** and choose the feature/comment-privacy-injection branch if it is not merged yet.
3. Paste a **direct HTTPS URL** to the RyukGram IPA into the ryukgram_ipa_url field. You may use your original RyukGram IPA **or an already-patched RyukGram + CommentPrivacy IPA** (or leave empty to build the dylib only).
4. Download the workflow artifact **RyukGram-CommentPrivacy-unsigned-IPA** or **CommentPrivacy-dylib**.
5. Sign the patched IPA again using ESign, Feather, etc., and install.

The workflow compiles an arm64 iOS dynamic library with the iPhoneOS SDK, then runs ipapatch --dylib on the supplied IPA. If the IPA has no CommentPrivacy dylib, this adds an additional load command and dylib. If CommentPrivacy is already present, the workflow replaces only its dylib binary and avoids a duplicate load command. Existing RyukGram files are retained.

## Important limits

**Not yet device-tested** on Instagram 452.0.1. Instagram is closed-source and changes view class names and accessibility labels. If a particular comment button is not labeled, the long-press gesture may not appear. If a comment row is not recognizable by its Objective-C class name, the author/portrait will not be hidden. The implementation deliberately avoids hiding generic username labels across the app, because doing so can conceal unrelated metadata. Real-device UI inspection and version-specific fixes may still be needed.

The source is a best-effort initial implementation rather than a guaranteed production-ready tweak. It has not been tested against a supplied RyukGram IPA yet. The IPA must be locally re-signed after patching; this cannot edit an already-installed iOS app in place.

Do not put an IPA with personal credentials or private content into a public artifact or public repository. If an IPA is attached privately in chat, it can be processed outside this URL-based workflow.

If something fails, collect the [CommentPrivacy] log message, Instagram version, and the exact comment button/view class or accessibility label. Source lives in CommentPrivacy/CommentPrivacy.m.

## Username detection fix (v2)

Instagram comment usernames may be displayed in an IGCoreTextView using an IGStyledString, not in their own UILabel. The code now recognizes those styled strings, removes only a distinctly styled username prefix from rendered text, and restores the original attributed text when disabled. It also reapplies the change after asynchronous label updates. The behavior still needs to be confirmed with a device build.
