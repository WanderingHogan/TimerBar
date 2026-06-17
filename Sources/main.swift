import Cocoa
import ServiceManagement
import UserNotifications

// MARK: - Model

final class CountdownTimer {
    let id = UUID()
    var label: String
    var color: NSColor
    var emoji: String
    var totalSeconds: Int
    var remainingSeconds: Int
    var reminderSeconds: Int   // notify this many seconds before finish; 0 = none
    var reminderFired: Bool = false
    var isRunning: Bool = true
    var isDone: Bool = false

    init(label: String, color: NSColor, emoji: String, totalSeconds: Int, reminderSeconds: Int) {
        self.label = label
        self.color = color
        self.emoji = emoji
        self.totalSeconds = totalSeconds
        self.remainingSeconds = totalSeconds
        self.reminderSeconds = reminderSeconds
    }
}

// MARK: - Time formatting

func formatTime(_ seconds: Int) -> String {
    let s = max(0, seconds)
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    if h > 0 {
        return String(format: "%d:%02d:%02d", h, m, sec)
    }
    return String(format: "%02d:%02d", m, sec)
}

// MARK: - Drawing helper

func circleImage(color: NSColor, diameter: CGFloat, selected: Bool) -> NSImage {
    let size = NSSize(width: diameter, height: diameter)
    let img = NSImage(size: size)
    img.lockFocus()
    if selected {
        NSColor.labelColor.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 0.75, y: 0.75, width: diameter - 1.5, height: diameter - 1.5))
        ring.lineWidth = 1.5
        ring.stroke()
    }
    let pad: CGFloat = selected ? 3.5 : 1
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: pad, y: pad, width: diameter - 2 * pad, height: diameter - 2 * pad)).fill()
    img.unlockFocus()
    img.isTemplate = false
    return img
}

// MARK: - Actions the popover can ask the app to perform

protocol TimerActions: AnyObject {
    var allTimers: [CountdownTimer] { get }
    func addTimer(_ timer: CountdownTimer)
    func togglePauseTimer(_ id: UUID)
    func restartTimer(_ id: UUID)
    func deleteTimer(_ id: UUID)
    /// Temporarily keep the popover open (true) while a separate panel like the
    /// emoji picker is up, or restore click-outside-to-close (false).
    func setPopoverSticky(_ sticky: Bool)
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate, TimerActions, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var timers: [CountdownTimer] = []
    private var ticker: Timer?

    private var popover: NSPopover!
    private var popoverVC: PopoverViewController!

    static let appIcon: NSImage? = {
        guard let path = Bundle.main.path(forResource: "TimerBar", ofType: "icns") else { return nil }
        return NSImage(contentsOfFile: path)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = AppDelegate.appIcon { NSApp.applicationIconImage = icon }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        popoverVC = PopoverViewController()
        popoverVC.actions = self
        popover = NSPopover()
        popover.contentViewController = popoverVC
        // Normal behavior: click outside to close. We temporarily flip to
        // .applicationDefined only while the emoji picker is open (see
        // setPopoverSticky) so that picker — a separate panel — doesn't dismiss it.
        // ROLLBACK: to go back to always-sticky, set this to .applicationDefined
        // and remove the setPopoverSticky calls.
        popover.behavior = .transient
        // Force the view to load now so preferredContentSize is established
        // before the first show (otherwise the popover opens at zero size).
        popoverVC.loadViewIfNeeded()
        popoverVC.refresh()

        // Esc closes the popover when it's open.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.popover.isShown == true {
                self?.popover.performClose(nil)
                return nil
            }
            return event
        }

        updateDisplay()

        // Schedule in .common mode so the countdown keeps ticking while the
        // popover (or any other tracking loop) is up.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        ticker = t

        setupNotifications()
    }

    // MARK: Notifications

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Snooze 5 Minutes", options: [])
        let dismiss = UNNotificationAction(identifier: "DISMISS", title: "Dismiss", options: [.destructive])
        let category = UNNotificationCategory(identifier: "TIMER_REMINDER",
                                              actions: [snooze, dismiss],
                                              intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func deliverReminder(for t: CountdownTimer, in seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        let name = t.label.isEmpty ? "Timer" : t.label
        content.title = t.emoji.isEmpty ? name : "\(t.emoji) \(name)"
        let mins = max(1, Int((seconds / 60).rounded()))
        content.body = "Finishes in about \(mins) minute\(mins == 1 ? "" : "s")."
        content.sound = .default
        content.categoryIdentifier = "TIMER_REMINDER"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show the banner even when the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Handle Snooze / Dismiss.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "SNOOZE",
           let content = response.notification.request.content.mutableCopy() as? UNMutableNotificationContent {
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 300, repeats: false)
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
            center.add(request)
        }
        completionHandler()
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.behavior = .transient   // reset in case it was left sticky
            popoverVC.reset()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: TimerActions

    var allTimers: [CountdownTimer] { timers }

    func addTimer(_ timer: CountdownTimer) {
        timers.append(timer)
        afterChange()
    }

    func togglePauseTimer(_ id: UUID) {
        if let t = timers.first(where: { $0.id == id }), !t.isDone {
            t.isRunning.toggle()
        }
        afterChange()
    }

    func restartTimer(_ id: UUID) {
        if let t = timers.first(where: { $0.id == id }) {
            t.remainingSeconds = t.totalSeconds
            t.isDone = false
            t.isRunning = true
            t.reminderFired = false
        }
        afterChange()
    }

    func deleteTimer(_ id: UUID) {
        timers.removeAll { $0.id == id }
        afterChange()
    }

    func setPopoverSticky(_ sticky: Bool) {
        popover.behavior = sticky ? .applicationDefined : .transient
    }

    private func afterChange() {
        popoverVC.refresh()
        updateDisplay()
    }

    // MARK: Ticking

    private func tick() {
        var changedStructure = false
        for t in timers where t.isRunning && !t.isDone {
            if t.remainingSeconds > 0 { t.remainingSeconds -= 1 }
            // Pre-finish reminder notification.
            if t.reminderSeconds > 0, !t.reminderFired,
               t.totalSeconds > t.reminderSeconds,
               t.remainingSeconds > 0, t.remainingSeconds <= t.reminderSeconds {
                t.reminderFired = true
                deliverReminder(for: t, in: TimeInterval(t.remainingSeconds))
            }
            if t.remainingSeconds <= 0 {
                t.remainingSeconds = 0
                t.isRunning = false
                t.isDone = true
                changedStructure = true
                fireDone(t)
            }
        }
        if changedStructure {
            popoverVC.refresh()
        } else {
            popoverVC.updateTimes()
        }
        updateDisplay()
    }

    private func fireDone(_ t: CountdownTimer) {
        // Non-intrusive slide-in banner instead of a modal alert.
        let content = UNMutableNotificationContent()
        let name = t.label.isEmpty ? "Timer" : t.label
        content.title = t.emoji.isEmpty ? name : "\(t.emoji) \(name)"
        content.body = "Timer finished."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Status-bar display

    private func updateDisplay() {
        guard let button = statusItem.button else { return }

        if timers.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Timers")
            statusItem.length = NSStatusItem.variableLength
            return
        }

        button.image = nil
        button.attributedTitle = compactString()
        statusItem.length = NSStatusItem.variableLength
    }

    private func compactString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        for (i, t) in timers.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "  ")) }
            if t.emoji.isEmpty {
                let dotColor = t.isDone ? t.color.withAlphaComponent(0.5) : t.color
                result.append(NSAttributedString(string: "\u{25CF} ", attributes: [.foregroundColor: dotColor, .font: font]))
            } else {
                result.append(NSAttributedString(string: t.emoji + " ", attributes: [.font: font]))
            }
            let timeStr = t.isDone ? "done" : formatTime(t.remainingSeconds)
            result.append(NSAttributedString(string: timeStr, attributes: [.font: font]))
        }
        return result
    }
}

// MARK: - Per-timer-row buttons (carry the timer id)

final class ActionButton: NSButton {
    var timerID: UUID?
}

// MARK: - Color swatch picker

final class SwatchPicker: NSView {
    private let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .systemPink, .systemGray
    ]
    private var buttons: [NSButton] = []
    private var selectedIndex = 4
    private var showsSelection = true
    /// Fired when the user clicks a swatch (so the emoji selection can clear).
    var onSelect: (() -> Void)?
    var selected: NSColor { colors[selectedIndex] }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (i, c) in colors.enumerated() {
            let b = NSButton()
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imagePosition = .imageOnly
            b.title = ""
            b.tag = i
            b.target = self
            b.action = #selector(pick(_:))
            b.image = circleImage(color: c, diameter: 18, selected: i == selectedIndex)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            buttons.append(b)
            stack.addArrangedSubview(b)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func resetSelection() {
        selectedIndex = 4
        showsSelection = true
        refreshImages()
    }

    /// Visually deselect all swatches (selection moved elsewhere, e.g. the emoji).
    func clearSelection() {
        showsSelection = false
        refreshImages()
    }

    @objc private func pick(_ sender: NSButton) {
        selectedIndex = sender.tag
        showsSelection = true
        refreshImages()
        onSelect?()
    }

    private func refreshImages() {
        for (i, b) in buttons.enumerated() {
            b.image = circleImage(color: colors[i], diameter: 18, selected: showsSelection && i == selectedIndex)
        }
    }
}

// MARK: - Popover content (the dropdown)

final class PopoverViewController: NSViewController, NSTextFieldDelegate {
    weak var actions: TimerActions?

    private let contentWidth: CGFloat = 300
    private let inset: CGFloat = 12
    private var innerWidth: CGFloat { contentWidth - inset * 2 }

    private var masterStack: NSStackView!
    private var newButton: NSButton!
    private var formStack: NSStackView!
    private var modeSeg: NSSegmentedControl!
    private var durationRow: NSStackView!
    private var timeRow: NSStackView!
    private var hoursField: NSTextField!
    private var minutesField: NSTextField!
    private var datePicker: NSDatePicker!
    private var labelField: NSTextField!
    private var reminderPopup: NSPopUpButton!
    private var swatches: SwatchPicker!
    private var emojiButton: NSButton!
    private var emojiCapture: NSTextField!   // invisible target for the emoji picker
    private var selectedEmoji = ""
    private var listStack: NSStackView!
    private var launchCheckbox: NSButton!
    private var rowTimeLabels: [UUID: NSTextField] = [:]

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 120))

        masterStack = NSStackView()
        masterStack.orientation = .vertical
        masterStack.alignment = .leading
        masterStack.spacing = 10
        masterStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(masterStack)
        NSLayoutConstraint.activate([
            masterStack.topAnchor.constraint(equalTo: root.topAnchor, constant: inset),
            masterStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            masterStack.widthAnchor.constraint(equalToConstant: innerWidth)
        ])

        // Header: app icon + name
        let iconView = NSImageView(image: AppDelegate.appIcon ?? NSImage())
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 22).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let titleLabel = NSTextField(labelWithString: "TimerBar")
        titleLabel.font = .boldSystemFont(ofSize: 13)
        let headerRow = NSStackView(views: [iconView, titleLabel])
        headerRow.orientation = .horizontal
        headerRow.spacing = 7
        masterStack.addArrangedSubview(headerRow)

        // "+ Create Timer" toggle
        newButton = NSButton(title: "  \u{2795}  Create Timer", target: self, action: #selector(showForm))
        newButton.bezelStyle = .rounded
        fullWidth(newButton)
        masterStack.addArrangedSubview(newButton)

        // Inline create form (hidden until toggled)
        buildForm()
        masterStack.addArrangedSubview(formStack)
        formStack.isHidden = true

        // Divider + header
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        masterStack.addArrangedSubview(sep)

        let header = NSTextField(labelWithString: "Timers")
        header.font = NSFont.boldSystemFont(ofSize: 11)
        header.textColor = .secondaryLabelColor
        masterStack.addArrangedSubview(header)

        // Active-timers list
        listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 6
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        masterStack.addArrangedSubview(listStack)

        // Footer: launch-at-login + Quit
        let footSep = NSBox()
        footSep.boxType = .separator
        footSep.translatesAutoresizingMaskIntoConstraints = false
        footSep.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        masterStack.addArrangedSubview(footSep)

        launchCheckbox = NSButton(checkboxWithTitle: "Launch at login",
                                  target: self, action: #selector(toggleLaunchAtLogin(_:)))
        masterStack.addArrangedSubview(launchCheckbox)

        let quit = NSButton(title: "Quit TimerBar", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .inline
        quit.controlSize = .small
        let bugs = NSButton(title: "Bugs/Requests", target: self, action: #selector(openBugs))
        bugs.bezelStyle = .inline
        bugs.controlSize = .small
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footerRow = NSStackView(views: [quit, footerSpacer, bugs])
        footerRow.orientation = .horizontal
        footerRow.spacing = 8
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        masterStack.addArrangedSubview(footerRow)

        // Invisible field the emoji picker inserts into. Must be in the hierarchy
        // and able to become first responder (so alpha 0, not isHidden).
        emojiCapture = NSTextField(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        emojiCapture.isBezeled = false
        emojiCapture.drawsBackground = false
        emojiCapture.alphaValue = 0
        emojiCapture.delegate = self
        root.addSubview(emojiCapture)

        self.view = root
        updateLaunchState()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        if #available(macOS 13.0, *) {
            do {
                if sender.state == .on {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSSound.beep()
            }
        }
        updateLaunchState()
    }

    private func updateLaunchState() {
        guard let box = launchCheckbox else { return }
        if #available(macOS 13.0, *) {
            box.isEnabled = true
            box.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        } else {
            box.isEnabled = false
            box.toolTip = "Requires macOS 13 or later"
        }
    }

    private func buildForm() {
        formStack = NSStackView()
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 8
        formStack.translatesAutoresizingMaskIntoConstraints = false
        formStack.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true

        modeSeg = NSSegmentedControl(labels: ["Duration", "At a time"],
                                     trackingMode: .selectOne,
                                     target: self, action: #selector(modeChanged))
        modeSeg.selectedSegment = 0
        fullWidth(modeSeg)
        formStack.addArrangedSubview(modeSeg)

        hoursField = numberField()
        minutesField = numberField()
        durationRow = NSStackView(views: [
            fieldLabel("Hours"), hoursField,
            fieldLabel("Minutes"), minutesField
        ])
        durationRow.orientation = .horizontal
        durationRow.spacing = 6
        formStack.addArrangedSubview(durationRow)

        datePicker = NSDatePicker()
        datePicker.datePickerStyle = .clockAndCalendar
        datePicker.datePickerElements = .hourMinute
        datePicker.dateValue = Date().addingTimeInterval(300)
        timeRow = NSStackView(views: [fieldLabel("At"), datePicker])
        timeRow.orientation = .horizontal
        timeRow.spacing = 6
        timeRow.isHidden = true
        formStack.addArrangedSubview(timeRow)

        labelField = NSTextField(string: "")
        labelField.placeholderString = "Label (optional)"
        fullWidth(labelField)
        formStack.addArrangedSubview(labelField)

        // Indicator: color swatches + a tappable emoji that opens the system
        // picker. Picking an emoji makes it (instead of the color dot) the menu
        // bar / dropdown indicator.
        swatches = SwatchPicker()
        swatches.translatesAutoresizingMaskIntoConstraints = false
        swatches.onSelect = { [weak self] in self?.selectColorIndicator() }
        emojiButton = NSButton(title: "\u{1F600}", target: self, action: #selector(chooseEmoji))
        emojiButton.isBordered = false
        emojiButton.font = .systemFont(ofSize: 18)
        emojiButton.toolTip = "Choose an emoji"
        emojiButton.wantsLayer = true
        emojiButton.layer?.cornerRadius = 6
        emojiButton.translatesAutoresizingMaskIntoConstraints = false
        emojiButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        emojiButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let indicatorRow = NSStackView(views: [fieldLabel("Indicator"), swatches, emojiButton])
        indicatorRow.orientation = .horizontal
        indicatorRow.spacing = 8
        formStack.addArrangedSubview(indicatorRow)

        // Reminder: optional system notification before the timer finishes.
        reminderPopup = NSPopUpButton()
        reminderPopup.addItems(withTitles: ["None", "5 minutes before", "15 minutes before"])
        let reminderRow = NSStackView(views: [fieldLabel("Reminder"), reminderPopup])
        reminderRow.orientation = .horizontal
        reminderRow.spacing = 6
        formStack.addArrangedSubview(reminderRow)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelForm))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let create = NSButton(title: "Create", target: self, action: #selector(createTapped))
        create.bezelStyle = .rounded
        create.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttonRow = NSStackView(views: [spacer, cancel, create])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        fullWidth(buttonRow)
        formStack.addArrangedSubview(buttonRow)
    }

    // MARK: Layout helpers

    private func fullWidth(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
    }

    private func fieldLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func numberField() -> NSTextField {
        let f = NSTextField(string: "")
        f.placeholderString = "0"
        f.alignment = .right
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: 46).isActive = true
        return f
    }

    private func updateSize() {
        masterStack.layoutSubtreeIfNeeded()
        let h = masterStack.fittingSize.height
        preferredContentSize = NSSize(width: contentWidth, height: h + inset * 2)
    }

    // MARK: Public refresh

    /// Called when opening the popover: collapse the form and rebuild the list.
    func reset() {
        collapseForm()
        refresh()
        updateLaunchState()
    }

    /// Rebuild the timers list (structural changes: add/remove/pause/restart/done).
    func refresh() {
        guard isViewLoaded else { return }
        rowTimeLabels.removeAll()
        for v in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let timers = actions?.allTimers ?? []
        if timers.isEmpty {
            let empty = NSTextField(labelWithString: "No active timers")
            empty.textColor = .tertiaryLabelColor
            listStack.addArrangedSubview(empty)
        } else {
            for t in timers { listStack.addArrangedSubview(makeRow(t)) }
        }
        updateSize()
    }

    /// Lightweight per-second update of just the countdown text.
    func updateTimes() {
        guard isViewLoaded else { return }
        let timers = actions?.allTimers ?? []
        for t in timers {
            rowTimeLabels[t.id]?.stringValue = rowText(t)
        }
    }

    private func rowText(_ t: CountdownTimer) -> String {
        let name = t.label.isEmpty ? "Timer" : t.label
        let time = t.isDone ? "done" : formatTime(t.remainingSeconds)
        let state = t.isDone ? "" : (t.isRunning ? "" : " · paused")
        return "\(name)   \(time)\(state)"
    }

    private func makeRow(_ t: CountdownTimer) -> NSView {
        let dot: NSView
        if t.emoji.isEmpty {
            dot = NSImageView(image: circleImage(color: t.color, diameter: 12, selected: false))
        } else {
            dot = NSTextField(labelWithString: t.emoji)
        }
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let name = NSTextField(labelWithString: rowText(t))
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        name.setContentHuggingPriority(.init(10), for: .horizontal)
        rowTimeLabels[t.id] = name

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let pause = iconButton(t.isRunning ? "pause.fill" : "play.fill", id: t.id, action: #selector(pauseTapped(_:)))
        pause.isEnabled = !t.isDone
        let restart = iconButton("arrow.counterclockwise", id: t.id, action: #selector(restartTapped(_:)))
        let trash = iconButton("trash", id: t.id, action: #selector(deleteTapped(_:)))

        let row = NSStackView(views: [dot, name, spacer, pause, restart, trash])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: innerWidth).isActive = true
        return row
    }

    private func iconButton(_ symbol: String, id: UUID, action: Selector) -> ActionButton {
        let b = ActionButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.bezelStyle = .texturedRounded
        b.setButtonType(.momentaryPushIn)
        b.imagePosition = .imageOnly
        b.timerID = id
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    // MARK: Form actions

    @objc private func showForm() {
        formStack.isHidden = false
        newButton.isHidden = true
        updateSize()
        view.window?.makeFirstResponder(hoursField)
    }

    @objc private func cancelForm() {
        collapseForm()
        updateSize()
    }

    private func collapseForm() {
        guard isViewLoaded else { return }
        formStack.isHidden = true
        newButton.isHidden = false
        hoursField.stringValue = ""
        minutesField.stringValue = ""
        labelField.stringValue = ""
        modeSeg.selectedSegment = 0
        durationRow.isHidden = false
        timeRow.isHidden = true
        datePicker.dateValue = Date().addingTimeInterval(300)
        swatches.resetSelection()
        selectedEmoji = ""
        emojiButton.title = "\u{1F600}"
        setEmojiSelected(false)
        emojiCapture.stringValue = ""
        reminderPopup.selectItem(at: 0)
    }

    @objc private func openBugs() {
        if let url = URL(string: "https://github.com/WanderingHogan/TimerBar") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func chooseEmoji() {
        // Keep the popover open while the picker panel (a separate window) is up,
        // then revert to click-outside-to-close once an emoji is inserted
        // (see controlTextDidChange).
        emojiCapture.stringValue = ""
        actions?.setPopoverSticky(true)
        view.window?.makeFirstResponder(emojiCapture)
        NSApp.orderFrontCharacterPalette(emojiCapture)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === emojiCapture else { return }
        guard let ch = emojiCapture.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).first else { return }
        selectedEmoji = String(ch)
        emojiButton.title = selectedEmoji
        setEmojiSelected(true)
        swatches.clearSelection()   // selection moves to the emoji
        actions?.setPopoverSticky(false)
    }

    /// User clicked a color swatch: it becomes the indicator, so drop the emoji.
    private func selectColorIndicator() {
        selectedEmoji = ""
        emojiButton.title = "\u{1F600}"
        setEmojiSelected(false)
    }

    private func setEmojiSelected(_ selected: Bool) {
        // Thin outline (like the color swatch ring), no fill.
        emojiButton.layer?.borderColor = NSColor.labelColor.cgColor
        emojiButton.layer?.borderWidth = selected ? 1.5 : 0
    }

    @objc private func modeChanged() {
        let duration = modeSeg.selectedSegment == 0
        durationRow.isHidden = !duration
        timeRow.isHidden = duration
        updateSize()
    }

    @objc private func createTapped() {
        let seconds = computeSeconds()
        guard seconds > 0 else { NSSound.beep(); return }
        let label = labelField.stringValue.trimmingCharacters(in: .whitespaces)
        let reminder = [0, 300, 900][reminderPopup.indexOfSelectedItem]
        let timer = CountdownTimer(label: label, color: swatches.selected, emoji: selectedEmoji,
                                   totalSeconds: seconds, reminderSeconds: reminder)
        collapseForm()
        actions?.addTimer(timer)   // triggers refresh() + status-bar update
    }

    private func computeSeconds() -> Int {
        if modeSeg.selectedSegment == 0 {
            let h = max(0, hoursField.integerValue)
            let m = max(0, minutesField.integerValue)
            return h * 3600 + m * 60
        } else {
            let cal = Calendar.current
            let now = Date()
            let comps = cal.dateComponents([.hour, .minute], from: datePicker.dateValue)
            guard let target = cal.nextDate(after: now,
                                            matching: DateComponents(hour: comps.hour, minute: comps.minute, second: 0),
                                            matchingPolicy: .nextTime) else { return 0 }
            return max(0, Int(target.timeIntervalSince(now).rounded()))
        }
    }

    // MARK: Row button actions

    @objc private func pauseTapped(_ sender: ActionButton) {
        if let id = sender.timerID { actions?.togglePauseTimer(id) }
    }

    @objc private func restartTapped(_ sender: ActionButton) {
        if let id = sender.timerID { actions?.restartTimer(id) }
    }

    @objc private func deleteTapped(_ sender: ActionButton) {
        if let id = sender.timerID { actions?.deleteTimer(id) }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
