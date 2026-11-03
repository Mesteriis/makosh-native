# Makosh shared appearance QA — 2026-10-16

Visual target: [selected matte-glass concept](main-window-matte-glass.png).
The user chose the second image of the last three and approved native implementation.
Follow-up scope: unify appearance across surfaces; preserve service content/layout.

## Scope and evidence

Source inventory found 169 matching public/internal View declarations. Scoped review
covers the main scene, service navigation, all six service containers, every explicit
custom color/background and sheet-presentation match, and separate native hosts
(calls, recording overlays, photo gallery). Individual views using inherited native
styles were not all read or executed. This is not exhaustive visual acceptance.

Shared dark appearance/accent is inherited by service views, native forms and sheets.
Common backgrounds, dossier, mail reading sheets and WhatsApp decoration are aligned.
Settings and separate call hosts are styled explicitly. Media canvases, avatars,
semantic warning/error/accept/hang-up colors and explicit Telegram chat themes remain
content-owned. HTML mail retains a neutral light document for authored black text;
its dark outer reader matches the workspace. JS/network/storage policy is unchanged.

Initial native capture found a P2: NavigationSplitView inserted a sidebar toggle and
moved the section menu to the split boundary. Removing that toolbar item twice did
not remove it on this runtime. The outer layout was changed to native HSplitView,
retaining the same service views, pane width bounds and mail folder column. Automatic
glass backgrounds on toolbar items were removed. Post-fix native capture confirms the extra toggle is absent, the dropdown is
immediately after traffic lights, title centered and settings trailing. The
source and implementation were opened together for comparison; service content
is intentionally different/preserved. Menu choices are proven by AX; the window
capture omits the separate system menu, so its pixels are not claimed matched.
Native widths/materials/selection/focus rings follow macOS rather than the raster.
The backdrop is deliberately quieter behind real text; exact gradient intensity
is remaining P3 polish, not claimed pixel equality.

Native checks already performed on isolated Teams QA (fake services, qa_teams_
schemas): section menu exposes all six entries; contacts empty state and new-contact
form; mail folder controls and account form; Telegram container and settings; empty
WhatsApp and meeting containers. Native forms are dark and inherited controls violet.
No real account, provider, OS consent, microphone/camera or private Keychain used.
Those initial captures precede HSplitView. Further HSplitView QA covers contacts
and populated Teams, menu keyboard selection, preserved selected conversation after
Teams → Contacts → Teams, native zoom (2400×1600 and3600×2130 pixels), populated
mail folders/list/text and safe HTML, rich compose typing with Cc/Bcc, populated
WhatsApp/contact/poll rows, photo editor/Cancel, and separate call preview/End.
Isolated mail/WhatsApp staging uses qa_mail_/qa_whatsapp_ schemas and fake boundaries.
No send/queue admission/provider call or device use was performed. UI is visible
and readable in the recorded captures. These QA copies precede three final small
decoration updates (reply tint, photo-strip border, mail selection/unread token);
final exact-artifact shell verification is recorded below.

Dossier visual acceptance is blocked: saving a synthetic contact closes the CUA
native pipe; one fresh read repeats the failure. The owned process remains alive.
No alternative UI backend, permission bypass or destructive data reset was used.
The original isolated schema/artifact is retained. This reproduces the previously
recorded dossier transport boundary; it is not evidence that the dossier passes.

Raw build/test/index and QA artifacts are retained under ignored .local/window-shell/.
First full scripts/test.sh exits 0: 2864 XCTest, one existing microphone-precondition
skip, zero failures; Rust/Python preparation checks also pass. This run predates
the final HSplitView changes and is not exact-final-source evidence. The first
HSplitView build failed after a cleanup removed two still-used preferences in
TelegramGeneralSettingsView. Both declarations were restored; final-source swift
build --product Makosh -j 4 then exits 0. Final scripts/test.sh now exits0 on the unchanged158-file app-source checkpoint:
2864 XCTest (WhatsApp142,Telemost74,Telegram2307,Teams108,Mail100,Core133), one
existing microphone-precondition skip, zero failures; Rust58, Python153/34runs.
Final canonical scripts/build-app.sh exits0; strict deep codesign passes.
The ordinary bundle, current compiled executable and QA004 executable text match,
and all158 app-source checkpoint hashes are unchanged. QA004 AX and actual pixels
confirm Contacts selection, dropdown placement and absence of sidebar toggle.
The final source/QA004 screenshot were opened together. ScreenCaptureKit3811 and
one30s timeout interrupted capture; a fresh same-backend read showed the menu was
already open, so the action was not repeated. Navigation completed via Return and
final-main.png was captured successfully. No capture failure is labelled PASS. An index run detected edits while indexing and correctly
refused to record freshness; it is not passing final-index evidence.

final result: blocked
