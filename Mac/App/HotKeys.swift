import Carbon.HIToolbox
import Foundation

/// Global hotkeys through Carbon `RegisterEventHotKey` — works without the Accessibility permission.
@MainActor
final class HotKeys {
    enum Action: Equatable {
        case nextPage, previousPage, page(Int), releasePointer
    }

    var onAction: ((Action) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: Action] = [:]
    private var handler: EventHandlerRef?

    func register() {
        let ctrlOpt = UInt32(controlKey | optionKey)
        var bindings: [(key: UInt32, modifiers: UInt32, action: Action)] = [
            (UInt32(kVK_RightArrow), ctrlOpt, .nextPage),
            (UInt32(kVK_LeftArrow), ctrlOpt, .previousPage),
            // Emergency: always brings the cursor back to the Mac.
            (UInt32(kVK_ANSI_P), ctrlOpt | UInt32(cmdKey), .releasePointer),
        ]
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                      kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, key) in digits.enumerated() { bindings.append((UInt32(key), ctrlOpt, .page(i))) }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                if let action = hotKeys.actions[id.id] { hotKeys.onAction?(action) }
            }
            return noErr
        }, 1, &spec, context, &handler)

        for (index, binding) in bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.key, binding.modifiers, EventHotKeyID(signature: OSType(0x5053_4352), id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id] = binding.action
            }
        }
    }
}
