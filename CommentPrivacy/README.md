## RyukGram v1.6.0 + Reels author privacy

Four independent switches are now available in the **same Comment Privacy menu**.
Long-press the Instagram **Comments** button to open the sheet:

| Comments section | Reels section |
| --- | --- |
| Hide Comment Usernames | Hide Reels Usernames |
| Hide Comment Avatars | Hide Reels Profile Pictures |

- The original two comment switches and their stored preference keys are unchanged.
- The Reels switches affect only recognised **Reels video author** UI, not users in comments, ordinary feed posts, profiles, stories or DMs.
- Reels targeting uses known Instagram native IGSundialViewerUserButton accessors (userNameLabel and profilePictureImageView) and IGSundialViewerUserAttributionView / video-overlay accessors, with conservative fallback matching. It does not hide the whole author panel, caption, music, or interaction buttons.
- All four switches default OFF for new installations; previous comment preferences are preserved if the app container is retained.

### Build RyukGram v1.6.0 and Comment Privacy in a single IPA

1. Open **Actions → Build sideloaded IPA from Release Assets** in this fork.
2. Provide a decrypted Instagram **456.0.0** IPA as a direct URL in the decrypted_instagram_url input. Use an unmodified Instagram IPA, **not an already RyukGram-injected IPA**.
3. Enter **v1.6.0** in the release_tag input (or leave empty if that is still the latest upstream release).
4. Leave **include_comment_privacy** ON (default); choose sideload or no-plugins build as usual.
5. Download the resulting IPA artifact, sign in ESign/Feather, and install.

That workflow downloads the official upstream RyukGram v1.6.0 release binaries while compiling the custom CommentPrivacy dylib from this fork. RyukGram and the Privacy add-on are injected separately; neither replaces the other. The default IPA flow does not require a second manual injection.

### Upgrade an already patched IPA

The separate **Build and inject Comment Privacy** workflow can replace the previous privacy dylib inside a patched IPA, but this **does not upgrade RyukGram itself**. To get upstream RyukGram v1.6.0, use the clean-Instagram-IPA build route above. Preserve your signing identity and original application bundle identifier to maintain the iOS app container where possible, and back up critical data before reinstalling.

**Compatibility warning:** Objective-C/Swift view class names change between Instagram versions. The v1.6.0/Instagram 456 native Reels privacy functionality is compile-tested, not confirmed on a physical device. A missing author component is left visible rather than masking unrelated content.


# Comment Privacy (experimental)

A separate iOS Objective-C dynamic library for the RyukGram-patched Instagram IPA. It does **not** replace RyukGram's own dylib, bundle, or settings.

## What it is designed to do

- Long-press a **Comment** button for 0.55 seconds to open **Comment Privacy**.
- Toggle two comment switches and two Reels author switches independently.
- All four switches default to OFF and persist in local app preferences.
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
