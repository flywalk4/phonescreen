import Foundation

/// Every message exchanged between the Mac agent and the iPhone client.
/// JSON shape: `{"t": "<type>", ...fields}`.
public enum Message: Equatable, Sendable {
    case hello(Hello)
    case ping(t: Double)
    case pong(t: Double)

    // Pages (Mac → phone: pages/setPage, phone → Mac: pageChanged)
    case pages(list: [PageInfo], current: Int)
    case setPage(index: Int)
    case pageChanged(index: Int)
    /// Mac → phone: how the phone sits next to the Mac (orientation + which side faces it).
    case layout(PhoneLayout)
    /// Phone → Mac: the accelerometer says the phone is held this way (only when tilted up, never lying flat).
    case orientation(PhoneOrientation)

    // Widget data (Mac → phone)
    case nowPlaying(NowPlaying?)
    case stats(SystemStats)

    // Notes (Apple Notes, read and written through the Mac)
    /// Mac → phone: most recently edited notes.
    case notes([NoteSummary])
    /// Phone → Mac: send the full text of a note.
    case noteRequest(id: String)
    /// Mac → phone: full plain text of a note.
    case noteBody(id: String, text: String)
    /// Phone → Mac: create a note (first line becomes the title).
    case noteCreate(text: String)
    /// Phone → Mac: open the note in Notes on the Mac.
    case noteShowOnMac(id: String)

    // Launcher
    /// Mac → phone: what can be launched.
    case launcher([LauncherItem])

    // Running apps
    /// Mac → phone: apps running on the Mac, most recently used first.
    case runningApps([RunningApp])
    /// Mac → phone: a JPEG snapshot of the app's front window; empty when it has no windows left.
    case appPreview(id: String, image: Data)
    /// Phone → Mac: switch to, hide or quit a running app.
    case appAction(id: String, action: AppAction)

    /// Phone → Mac: a page became visible; send fresh data for it now.
    case refresh(WidgetKind)

    // JavaScript widgets (run on the Mac; the phone only draws their resolved UI)
    /// Mac → phone: a widget's current UI (after every refresh).
    case customWidget(CustomWidgetState)
    /// Mac → phone: a widget was uninstalled.
    case customWidgetRemoved(id: String)
    /// Phone → Mac: a button in a widget was pressed.
    case customAction(id: String, action: String)

    /// Mac → phone: the look of every page and widget.
    case theme(Theme)
    /// Mac → phone: the language the product is in ("ru", "en"…); the phone's own texts follow it.
    case language(String)

    /// Mac → phone: tracks coming up.
    case musicQueue(MusicQueue)
    /// Mac → phone: system volume and AirPlay speakers.
    case audio(AudioState)
    /// Phone → Mac: volume, seek, shuffle, repeat, like, queue, AirPlay.
    case music(MusicCommand)

    // Actions (phone → Mac)
    case mediaAction(MediaAction)
    case command(id: String)

    // Pointer. `along` = position along the phone side that faces the Mac, 0…1
    // (top→bottom for a left/right side, left→right for a top/bottom side, in the phone's upright UI).
    /// Mac → phone: the cursor crossed onto the phone.
    case pointerEnter(along: Double)
    /// Mac → phone: movement while captured, already in phone UI points.
    case pointerDelta(dx: Double, dy: Double)
    case pointerButton(button: PointerButton, down: Bool)
    /// Scroll / two-finger swipe, in phone points, with the trackpad gesture phase.
    case pointerScroll(dx: Double, dy: Double, phase: ScrollPhase)
    /// Phone → Mac: the pointer left through the Mac-facing side. Mac → phone: capture ended on the Mac's side.
    case pointerExit(along: Double)
    /// Mac → phone: trackpad pinch step (positive = spread, negative = pinch in).
    case pointerPinch(magnification: Double, phase: ScrollPhase)
    /// Mac → phone: two-finger double tap on the trackpad (smart zoom).
    case pointerSmartZoom

    // Keyboard: while the pointer is on the phone and a text field there has focus, the Mac keyboard types into it.
    /// Phone → Mac: a text field gained / lost focus.
    case textFocus(Bool)
    /// Mac → phone: typed text (already resolved through the Mac keyboard layout), or a pasted string.
    case keyText(String)
    /// Mac → phone: an editing key.
    case key(SpecialKey)

    // Second screen: the phone is a real (virtual) display of the Mac, streamed as H.264.
    /// Mac → phone: a virtual display for the phone exists and frames of this size follow.
    case displayStart(DisplayStreamInfo)
    /// Mac → phone: one H.264 access unit in Annex B form; key frames carry SPS and PPS first.
    case displayFrame(data: Data, key: Bool)
    /// Mac → phone: the virtual display is gone.
    case displayStop
    /// Phone → Mac: the second-screen page appeared / disappeared.
    case displayVisible(Bool)
    /// Phone → Mac: the decoder needs a key frame (it just started, or lost one).
    case displayKeyframe
    /// Phone → Mac: a touch at `x`, `y` (0…1 across the picture).
    case displayTouch(phase: DisplayTouchPhase, x: Double, y: Double)
    /// Phone → Mac: two-finger scroll, in display points.
    case displayScroll(dx: Double, dy: Double)

    // Welcome tour
    /// Mac → phone: the tour's step to show over the pages (`nil`: the tour is over).
    case tour(TourStep?)
    /// Phone → Mac: the user did what the tour asked on the phone.
    case tourEvent(TourEvent)
}

/// What the phone shows while the Mac's welcome tour is open.
public enum TourStep: String, Codable, Sendable {
    /// Just connected: a hello.
    case hello
    /// "Bring the Mac's cursor here and click."
    case cursor
    /// "Now tap with your finger."
    case touch
    /// All set.
    case finish
}

public enum TourEvent: String, Codable, Sendable {
    /// Clicked with the Mac's pointer.
    case clicked
    /// Tapped with a finger.
    case touched
}

extension Message: Codable {
    private enum Kind: String, Codable {
        case hello, ping, pong, pages, setPage, pageChanged, layout, nowPlaying, stats, mediaAction, command
        case notes, noteRequest, noteBody, noteCreate, noteShowOnMac, launcher, refresh, musicQueue, audio, music
        case customWidget, customWidgetRemoved, customAction, theme, runningApps, appAction, appPreview, language
        case pointerEnter, pointerDelta, pointerButton, pointerScroll, pointerExit, textFocus, keyText, key
        case pointerPinch, pointerSmartZoom, orientation
        case displayStart, displayFrame, displayStop, displayVisible, displayKeyframe, displayTouch, displayScroll
        case tour, tourEvent
    }

    private enum Keys: String, CodingKey {
        case t, hello, list, current, index, value, id, along, dx, dy, button, down, phase, text, magnification, key, x, y
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .t) {
        case .hello: self = .hello(try c.decode(Hello.self, forKey: .hello))
        case .ping: self = .ping(t: try c.decode(Double.self, forKey: .value))
        case .pong: self = .pong(t: try c.decode(Double.self, forKey: .value))
        case .pages: self = .pages(list: try c.decode([PageInfo].self, forKey: .list),
                                   current: try c.decode(Int.self, forKey: .current))
        case .setPage: self = .setPage(index: try c.decode(Int.self, forKey: .index))
        case .pageChanged: self = .pageChanged(index: try c.decode(Int.self, forKey: .index))
        case .layout: self = .layout(try c.decode(PhoneLayout.self, forKey: .value))
        case .orientation: self = .orientation(try c.decode(PhoneOrientation.self, forKey: .value))
        case .nowPlaying: self = .nowPlaying(try c.decodeIfPresent(NowPlaying.self, forKey: .value))
        case .stats: self = .stats(try c.decode(SystemStats.self, forKey: .value))
        case .mediaAction: self = .mediaAction(try c.decode(MediaAction.self, forKey: .value))
        case .command: self = .command(id: try c.decode(String.self, forKey: .id))
        case .notes: self = .notes(try c.decode([NoteSummary].self, forKey: .list))
        case .noteRequest: self = .noteRequest(id: try c.decode(String.self, forKey: .id))
        case .noteBody: self = .noteBody(id: try c.decode(String.self, forKey: .id), text: try c.decode(String.self, forKey: .text))
        case .noteCreate: self = .noteCreate(text: try c.decode(String.self, forKey: .text))
        case .noteShowOnMac: self = .noteShowOnMac(id: try c.decode(String.self, forKey: .id))
        case .launcher: self = .launcher(try c.decode([LauncherItem].self, forKey: .list))
        case .runningApps: self = .runningApps(try c.decode([RunningApp].self, forKey: .list))
        case .appPreview: self = .appPreview(id: try c.decode(String.self, forKey: .id), image: try c.decode(Data.self, forKey: .value))
        case .appAction: self = .appAction(id: try c.decode(String.self, forKey: .id), action: try c.decode(AppAction.self, forKey: .value))
        case .refresh: self = .refresh(try c.decode(WidgetKind.self, forKey: .value))
        case .customWidget: self = .customWidget(try c.decode(CustomWidgetState.self, forKey: .value))
        case .customWidgetRemoved: self = .customWidgetRemoved(id: try c.decode(String.self, forKey: .id))
        case .customAction: self = .customAction(id: try c.decode(String.self, forKey: .id), action: try c.decode(String.self, forKey: .text))
        case .theme: self = .theme(try c.decode(Theme.self, forKey: .value))
        case .language: self = .language(try c.decode(String.self, forKey: .text))
        case .musicQueue: self = .musicQueue(try c.decode(MusicQueue.self, forKey: .value))
        case .audio: self = .audio(try c.decode(AudioState.self, forKey: .value))
        case .music: self = .music(try c.decode(MusicCommand.self, forKey: .value))
        case .pointerEnter: self = .pointerEnter(along: try c.decode(Double.self, forKey: .along))
        case .pointerDelta: self = .pointerDelta(dx: try c.decode(Double.self, forKey: .dx),
                                                 dy: try c.decode(Double.self, forKey: .dy))
        case .pointerButton: self = .pointerButton(button: try c.decode(PointerButton.self, forKey: .button),
                                                   down: try c.decode(Bool.self, forKey: .down))
        case .pointerScroll: self = .pointerScroll(dx: try c.decode(Double.self, forKey: .dx),
                                                   dy: try c.decode(Double.self, forKey: .dy),
                                                   phase: try c.decode(ScrollPhase.self, forKey: .phase))
        case .pointerExit: self = .pointerExit(along: try c.decode(Double.self, forKey: .along))
        case .pointerPinch: self = .pointerPinch(magnification: try c.decode(Double.self, forKey: .magnification),
                                                 phase: try c.decode(ScrollPhase.self, forKey: .phase))
        case .pointerSmartZoom: self = .pointerSmartZoom
        case .textFocus: self = .textFocus(try c.decode(Bool.self, forKey: .value))
        case .keyText: self = .keyText(try c.decode(String.self, forKey: .text))
        case .key: self = .key(try c.decode(SpecialKey.self, forKey: .value))
        case .displayStart: self = .displayStart(try c.decode(DisplayStreamInfo.self, forKey: .value))
        case .displayFrame: self = .displayFrame(data: try c.decode(Data.self, forKey: .value),
                                                 key: try c.decode(Bool.self, forKey: .key))
        case .displayStop: self = .displayStop
        case .displayVisible: self = .displayVisible(try c.decode(Bool.self, forKey: .value))
        case .displayKeyframe: self = .displayKeyframe
        case .displayTouch: self = .displayTouch(phase: try c.decode(DisplayTouchPhase.self, forKey: .phase),
                                                 x: try c.decode(Double.self, forKey: .x), y: try c.decode(Double.self, forKey: .y))
        case .displayScroll: self = .displayScroll(dx: try c.decode(Double.self, forKey: .dx),
                                                   dy: try c.decode(Double.self, forKey: .dy))
        case .tour: self = .tour(try c.decodeIfPresent(TourStep.self, forKey: .value))
        case .tourEvent: self = .tourEvent(try c.decode(TourEvent.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .hello(let v): try c.encode(Kind.hello, forKey: .t); try c.encode(v, forKey: .hello)
        case .ping(let t): try c.encode(Kind.ping, forKey: .t); try c.encode(t, forKey: .value)
        case .pong(let t): try c.encode(Kind.pong, forKey: .t); try c.encode(t, forKey: .value)
        case .pages(let list, let current):
            try c.encode(Kind.pages, forKey: .t); try c.encode(list, forKey: .list); try c.encode(current, forKey: .current)
        case .setPage(let i): try c.encode(Kind.setPage, forKey: .t); try c.encode(i, forKey: .index)
        case .pageChanged(let i): try c.encode(Kind.pageChanged, forKey: .t); try c.encode(i, forKey: .index)
        case .layout(let v): try c.encode(Kind.layout, forKey: .t); try c.encode(v, forKey: .value)
        case .orientation(let v): try c.encode(Kind.orientation, forKey: .t); try c.encode(v, forKey: .value)
        case .nowPlaying(let v): try c.encode(Kind.nowPlaying, forKey: .t); try c.encodeIfPresent(v, forKey: .value)
        case .stats(let v): try c.encode(Kind.stats, forKey: .t); try c.encode(v, forKey: .value)
        case .mediaAction(let v): try c.encode(Kind.mediaAction, forKey: .t); try c.encode(v, forKey: .value)
        case .command(let id): try c.encode(Kind.command, forKey: .t); try c.encode(id, forKey: .id)
        case .notes(let v): try c.encode(Kind.notes, forKey: .t); try c.encode(v, forKey: .list)
        case .noteRequest(let id): try c.encode(Kind.noteRequest, forKey: .t); try c.encode(id, forKey: .id)
        case .noteBody(let id, let text):
            try c.encode(Kind.noteBody, forKey: .t); try c.encode(id, forKey: .id); try c.encode(text, forKey: .text)
        case .noteCreate(let text): try c.encode(Kind.noteCreate, forKey: .t); try c.encode(text, forKey: .text)
        case .noteShowOnMac(let id): try c.encode(Kind.noteShowOnMac, forKey: .t); try c.encode(id, forKey: .id)
        case .launcher(let v): try c.encode(Kind.launcher, forKey: .t); try c.encode(v, forKey: .list)
        case .runningApps(let v): try c.encode(Kind.runningApps, forKey: .t); try c.encode(v, forKey: .list)
        case .appPreview(let id, let image):
            try c.encode(Kind.appPreview, forKey: .t); try c.encode(id, forKey: .id); try c.encode(image, forKey: .value)
        case .appAction(let id, let action):
            try c.encode(Kind.appAction, forKey: .t); try c.encode(id, forKey: .id); try c.encode(action, forKey: .value)
        case .refresh(let v): try c.encode(Kind.refresh, forKey: .t); try c.encode(v, forKey: .value)
        case .customWidget(let v): try c.encode(Kind.customWidget, forKey: .t); try c.encode(v, forKey: .value)
        case .customWidgetRemoved(let id): try c.encode(Kind.customWidgetRemoved, forKey: .t); try c.encode(id, forKey: .id)
        case .customAction(let id, let action):
            try c.encode(Kind.customAction, forKey: .t); try c.encode(id, forKey: .id); try c.encode(action, forKey: .text)
        case .theme(let v): try c.encode(Kind.theme, forKey: .t); try c.encode(v, forKey: .value)
        case .language(let v): try c.encode(Kind.language, forKey: .t); try c.encode(v, forKey: .text)
        case .musicQueue(let v): try c.encode(Kind.musicQueue, forKey: .t); try c.encode(v, forKey: .value)
        case .audio(let v): try c.encode(Kind.audio, forKey: .t); try c.encode(v, forKey: .value)
        case .music(let v): try c.encode(Kind.music, forKey: .t); try c.encode(v, forKey: .value)
        case .pointerEnter(let a): try c.encode(Kind.pointerEnter, forKey: .t); try c.encode(a, forKey: .along)
        case .pointerDelta(let dx, let dy):
            try c.encode(Kind.pointerDelta, forKey: .t); try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
        case .pointerButton(let b, let down):
            try c.encode(Kind.pointerButton, forKey: .t); try c.encode(b, forKey: .button); try c.encode(down, forKey: .down)
        case .pointerScroll(let dx, let dy, let phase):
            try c.encode(Kind.pointerScroll, forKey: .t); try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
            try c.encode(phase, forKey: .phase)
        case .pointerExit(let a): try c.encode(Kind.pointerExit, forKey: .t); try c.encode(a, forKey: .along)
        case .pointerPinch(let m, let phase):
            try c.encode(Kind.pointerPinch, forKey: .t); try c.encode(m, forKey: .magnification); try c.encode(phase, forKey: .phase)
        case .pointerSmartZoom: try c.encode(Kind.pointerSmartZoom, forKey: .t)
        case .textFocus(let v): try c.encode(Kind.textFocus, forKey: .t); try c.encode(v, forKey: .value)
        case .keyText(let v): try c.encode(Kind.keyText, forKey: .t); try c.encode(v, forKey: .text)
        case .key(let v): try c.encode(Kind.key, forKey: .t); try c.encode(v, forKey: .value)
        case .displayStart(let v): try c.encode(Kind.displayStart, forKey: .t); try c.encode(v, forKey: .value)
        case .displayFrame(let data, let key):
            try c.encode(Kind.displayFrame, forKey: .t); try c.encode(data, forKey: .value); try c.encode(key, forKey: .key)
        case .displayStop: try c.encode(Kind.displayStop, forKey: .t)
        case .displayVisible(let v): try c.encode(Kind.displayVisible, forKey: .t); try c.encode(v, forKey: .value)
        case .displayKeyframe: try c.encode(Kind.displayKeyframe, forKey: .t)
        case .displayTouch(let phase, let x, let y):
            try c.encode(Kind.displayTouch, forKey: .t); try c.encode(phase, forKey: .phase)
            try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        case .displayScroll(let dx, let dy):
            try c.encode(Kind.displayScroll, forKey: .t); try c.encode(dx, forKey: .dx); try c.encode(dy, forKey: .dy)
        case .tour(let v): try c.encode(Kind.tour, forKey: .t); try c.encodeIfPresent(v, forKey: .value)
        case .tourEvent(let v): try c.encode(Kind.tourEvent, forKey: .t); try c.encode(v, forKey: .value)
        }
    }
}

public enum MessageCoder {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
}
