// Deci/Views/Music/MusicSpeakerView.swift
import AppKit
import SwiftUI

/// The speaker on a cover that is in the player, as an image view. While audio plays its waves light up one after the
/// other, as an AppKit symbol effect, which the render server plays: the SwiftUI `symbolEffect` that did this redraws
/// its view every display frame, and each of those frames ran the whole popup window's update and layout (60 a second
/// for every playing cover on screen). Paused, the symbol stands lit.
@MainActor
final class MusicSpeakerView: NSImageView {
    /// How many times the effect was added (once per play, and again if the view came back to a window).
    private(set) var effectsAdded = 0
    private(set) var isPlaying = false
    private var symbolSize: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleNone
        contentTintColor = .white
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A layer that leaves the screen can lose its effect: bring it back with the view.
        if window != nil, isPlaying {
            removeAllSymbolEffects(animated: false)
            startEffect()
        }
    }

    /// The symbol's size in points, semibold.
    func configure(symbolSize newSize: CGFloat) {
        guard newSize != symbolSize else { return }
        symbolSize = newSize
        let configuration = NSImage.SymbolConfiguration(pointSize: newSize, weight: .semibold)
        image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    /// Starts or stops the waves. Asking for what already is does nothing.
    func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        if playing {
            startEffect()
        } else {
            removeAllSymbolEffects()
        }
    }

    private func startEffect() {
        addSymbolEffect(.variableColor.iterative, options: .repeating)
        effectsAdded += 1
    }
}

/// The speaker in SwiftUI.
struct MusicSpeaker: NSViewRepresentable {
    let isPlaying: Bool
    let symbolSize: CGFloat

    /// The waves play only while the popup is on screen, as the playing row's spectrum does: the popup's window is kept
    /// when it closes, and a symbol effect left running in it would go on being played for nobody.
    @Environment(\.musicPopupIsVisible) private var isPopupVisible

    func makeNSView(context: Context) -> MusicSpeakerView {
        let view = MusicSpeakerView(frame: .zero)
        view.configure(symbolSize: symbolSize)
        view.setPlaying(isPlaying && isPopupVisible)
        return view
    }

    func updateNSView(_ view: MusicSpeakerView, context: Context) {
        view.configure(symbolSize: symbolSize)
        view.setPlaying(isPlaying && isPopupVisible)
    }
}
