import UIKit
import Flutter

// MARK: - Factory
class iOS26ToolbarFactory: NSObject, FlutterPlatformViewFactory {
    private var messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        return iOS26ToolbarPlatformView(
            frame: frame,
            viewIdentifier: viewId,
            arguments: args,
            binaryMessenger: messenger
        )
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

// UIKit measures this transparent title slot against its actual bar-button groups. Flutter
// draws the title, but must use these bounds rather than estimating widths from action counts.
private class ToolbarTitleSlot: UIView {
    var onLayout: (() -> Void)?

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.layoutFittingExpandedSize.width, height: 44)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        intrinsicContentSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

// MARK: - Platform View
class iOS26ToolbarPlatformView: NSObject, FlutterPlatformView {
    private var containerView: UIView
    private var navigationBar: UINavigationBar
    private var navigationItem: UINavigationItem
    private var channel: FlutterMethodChannel

    private var isDark: Bool = false
    private var isRtl: Bool = false
    private var perActionTintTags: Set<Int> = []
    private let titleSlot = ToolbarTitleSlot(frame: CGRect(x: 0, y: 0, width: UIView.layoutFittingExpandedSize.width, height: 44))
    private var lastTitleInsets: UIEdgeInsets?

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        containerView = UIView(frame: frame)
        navigationBar = UINavigationBar()
        navigationItem = UINavigationItem()
        channel = FlutterMethodChannel(
            name: "adaptive_platform_ui/ios26_toolbar_\(viewId)",
            binaryMessenger: messenger
        )

        if let params = args as? [String: Any] {
            isDark = params["isDark"] as? Bool ?? false
            isRtl = params["isRtl"] as? Bool ?? false
        }

        super.init()

        setupNavigationBar()
        titleSlot.isUserInteractionEnabled = false
        titleSlot.accessibilityElementsHidden = true
        titleSlot.onLayout = { [weak self] in
            // UINavigationBar can still be laying out its children in this callback.
            DispatchQueue.main.async { [weak self] in self?.reportTitleInsets() }
        }
        if let params = args as? [String: Any] { applyConfiguration(params) }
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { result(nil); return }
            self.handleMethodCall(call, result: result)
        }
    }

    deinit {
        channel.setMethodCallHandler(nil)
    }

    func view() -> UIView {
        return containerView
    }

    private func setupNavigationBar() {
        containerView.backgroundColor = .clear

        // Flutter owns the scroll backing; only the controls carry native Liquid Glass.
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        navigationBar.items = [navigationItem]

        // Configure transparent appearance
        if #available(iOS 13.0, *) {
            let appearance = UINavigationBarAppearance()
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = .clear
            appearance.shadowColor = .clear
            navigationBar.standardAppearance = appearance
            navigationBar.scrollEdgeAppearance = appearance
            if #available(iOS 15.0, *) {
                navigationBar.compactAppearance = appearance
            }
        }

        containerView.addSubview(navigationBar)

        // Centre UIKit's 44-point control band with the Flutter overlay. The taller container
        // includes the clearance that the content inset and scroll backing reserve.
        NSLayoutConstraint.activate([
            navigationBar.centerYAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.centerYAnchor),
            navigationBar.heightAnchor.constraint(equalToConstant: 44),
            navigationBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            navigationBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
        ])
    }

    private func applyConfiguration(_ params: [String: Any]) {
        isDark = params["isDark"] as? Bool ?? false
        isRtl = params["isRtl"] as? Bool ?? false
        containerView.overrideUserInterfaceStyle = isDark ? .dark : .light
        applyDirectionality()
        navigationItem.title = params["title"] as? String
        navigationItem.titleView = params["hasTitleWidget"] as? Bool == true ? titleSlot : nil
        perActionTintTags.removeAll()
        configureItems(params)
        let tint = (params["tint"] as? NSNumber).map { Self.colorFromARGB($0.intValue) }
        containerView.tintColor = tint
        navigationBar.tintColor = tint
        for item in (navigationItem.leftBarButtonItems ?? []) + (navigationItem.rightBarButtonItems ?? []) {
            if !perActionTintTags.contains(item.tag) { item.tintColor = tint }
        }
        navigationBar.setNeedsLayout()
        navigationBar.layoutIfNeeded()
        // Also reply after creation: the initial layout can precede Dart's channel handler.
        DispatchQueue.main.async { [weak self] in self?.reportTitleInsets(force: true) }
    }

    private func reportTitleInsets(force: Bool = false) {
        guard navigationItem.titleView === titleSlot, titleSlot.superview != nil,
              containerView.bounds.width > 0, titleSlot.bounds.width > 0 else { return }
        let frame = titleSlot.convert(titleSlot.bounds, to: containerView)
        let insets = UIEdgeInsets(top: 0, left: max(0, frame.minX), bottom: 0,
                                  right: max(0, containerView.bounds.width - frame.maxX))
        guard force || insets != lastTitleInsets else { return }
        lastTitleInsets = insets
        channel.invokeMethod("onTitleInsetsChanged", arguments: [
            "left": insets.left, "right": insets.right
        ])
    }

    private func configureItems(_ params: [String: Any]) {
        // Title
        if let title = params["title"] as? String {
            navigationItem.title = title
        }

        // Leading/Back button
        var leadingItems: [UIBarButtonItem] = []

        // A Flutter-overlaid leading control is invisible to UIKit, so the bar centres its
        // title across the full width and a long title runs underneath the overlay. The
        // fixed-space placeholder claims the same slot inside the bar's own layout, which
        // makes long titles truncate against it instead — and it mirrors with the bar's
        // semantic direction, so the reservation lands on the correct side in RTL.
        if params["reservesLeading"] as? Bool == true {
            let placeholder = UIBarButtonItem(
                barButtonSystemItem: .fixedSpace, target: nil, action: nil)
            placeholder.width = 52
            placeholder.isEnabled = false
            leadingItems.append(placeholder)
        }

        if let leading = params["leading"] as? String {
            let leadingButton: UIBarButtonItem
            if leading.isEmpty {
                // The concrete glyph, chosen by the bar's own direction: the semantic
                // chevron.backward resolves against the *device* direction at image creation,
                // which this view may be overriding for the app's locale.
                leadingButton = UIBarButtonItem(
                    image: UIImage(systemName: isRtl ? "chevron.right" : "chevron.left"),
                    style: .plain,
                    target: self,
                    action: #selector(leadingTapped)
                )
            } else {
                leadingButton = UIBarButtonItem(
                    title: leading,
                    style: .plain,
                    target: self,
                    action: #selector(leadingTapped)
                )
            }
            leadingItems.append(leadingButton)
        }

        // Process actions
        var leftGroup: [UIBarButtonItem] = []
        var rightGroup: [UIBarButtonItem] = []

        if let actions = params["actions"] as? [[String: Any]] {
            // First pass: check if any flexible spacer exists
            let hasFlexible = actions.contains { ($0["spacerAfter"] as? Int) == 2 }

            // Second pass: build buttons
            var foundFlexible = false

            for (index, action) in actions.enumerated() {
                var button: UIBarButtonItem?

                if let icon = action["icon"] as? String {
                    button = UIBarButtonItem(
                        image: UIImage(systemName: icon) ?? UIImage(named: icon),
                        style: .plain,
                        target: self,
                        action: #selector(actionTapped(_:))
                    )
                } else if let title = action["title"] as? String {
                    button = UIBarButtonItem(
                        title: title,
                        style: .plain,
                        target: self,
                        action: #selector(actionTapped(_:))
                    )
                }

                if let btn = button {
                    btn.tag = index
                    btn.accessibilityLabel = action["accessibilityLabel"] as? String
                    btn.isEnabled = action["enabled"] as? Bool ?? true

                    // Apply prominent style (iOS 26+)
                    if action["prominent"] as? Bool == true {
                        if #available(iOS 26.0, *) {
                            btn.style = .prominent
                        }
                    }

                    // Apply per-action tint color
                    if let n = action["tint"] as? NSNumber {
                        btn.tintColor = Self.colorFromARGB(n.intValue)
                        perActionTintTags.insert(index)
                    }

                    // If no flexible spacer exists, all go to right
                    // If flexible exists, split by it
                    if !hasFlexible {
                        rightGroup.append(btn)
                    } else if !foundFlexible {
                        leftGroup.append(btn)
                    } else {
                        rightGroup.append(btn)
                    }

                    // Check for spacers
                    if let spacerAfter = action["spacerAfter"] as? Int {
                        if spacerAfter == 1 {
                            // Fixed space
                            if #available(iOS 16.0, *) {
                                if !hasFlexible {
                                    rightGroup.append(.fixedSpace(12))
                                } else if !foundFlexible {
                                    leftGroup.append(.fixedSpace(12))
                                } else {
                                    rightGroup.append(.fixedSpace(12))
                                }
                            }
                        } else if spacerAfter == 2 {
                            // Flexible spacer - mark split point
                            foundFlexible = true
                        }
                    }
                }
            }
        }

        // Assign to navigation item
        navigationItem.leftBarButtonItems = leadingItems + leftGroup
        navigationItem.rightBarButtonItems = rightGroup.reversed()
    }

    @objc private func leadingTapped() {
        channel.invokeMethod("onLeadingTapped", arguments: nil)
    }

    @objc private func actionTapped(_ sender: UIBarButtonItem) {
        channel.invokeMethod("onActionTapped", arguments: ["index": sender.tag])
    }

    /// The app's locale decides the bar's direction, not the device's. UINavigationItem swaps
    /// its left/right item groups under `forceRightToLeft`, which is exactly the mirroring the
    /// Flutter side expects; the trait override reaches the iOS 26 glass content, same as the
    /// tab bar.
    private func applyDirectionality() {
        let attribute: UISemanticContentAttribute = isRtl
            ? .forceRightToLeft
            : .forceLeftToRight
        navigationBar.semanticContentAttribute = attribute
        containerView.semanticContentAttribute = attribute
        if #available(iOS 17.0, *) {
            navigationBar.traitOverrides.layoutDirection = isRtl ? .rightToLeft : .leftToRight
        }
    }

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "updateConfiguration":
            if let args = call.arguments as? [String: Any] { applyConfiguration(args) }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static func colorFromARGB(_ argb: Int) -> UIColor {
        let a = CGFloat((argb >> 24) & 0xFF) / 255.0
        let r = CGFloat((argb >> 16) & 0xFF) / 255.0
        let g = CGFloat((argb >> 8) & 0xFF) / 255.0
        let b = CGFloat(argb & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}
