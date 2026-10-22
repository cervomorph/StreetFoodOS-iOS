import UIKit

/// Full-screen PIN lock. Two modes:
///   .setup  — first run / re-protect: choose a PIN, then confirm it
///   .unlock — enter the PIN to open the encrypted cache
final class LockViewController: UIViewController {

    enum Mode { case setup, unlock }

    private let mode: Mode
    private let onDone: () -> Void

    private var pin = ""
    private var firstEntry: String?
    private let dots = UILabel()
    private let message = UILabel()
    private let pad = UIStackView()
    private let forgotButton = UIButton(type: .system)

    init(mode: Mode, onDone: @escaping () -> Void) {
        self.mode = mode
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0x1a/255.0, green: 0x1d/255.0, blue: 0x23/255.0, alpha: 1)

        let title = UILabel()
        title.text = mode == .setup ? "Protect this device" : "StreetFood OS is locked"
        title.textColor = .white
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textAlignment = .center

        message.text = mode == .setup
            ? "Choose a 4-digit PIN. Saved pages are encrypted with it — without it they cannot be read."
            : "Enter your PIN to open the saved pages."
        message.textColor = UIColor(red: 0xe2/255.0, green: 0xe8/255.0, blue: 0xf0/255.0, alpha: 0.7)
        message.font = .systemFont(ofSize: 13)
        message.numberOfLines = 0
        message.textAlignment = .center

        dots.text = pinDots()
        dots.textColor = .white
        dots.font = .systemFont(ofSize: 26, weight: .medium)
        dots.textAlignment = .center

        pad.axis = .vertical
        pad.spacing = 10
        let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", "⌫"]]
        for row in rows {
            let line = UIStackView()
            line.axis = .horizontal
            line.distribution = .fillEqually
            line.spacing = 10
            for key in row {
                if key.isEmpty {
                    line.addArrangedSubview(UIView())
                    continue
                }
                let button = UIButton(type: .system)
                button.setTitle(key, for: .normal)
                button.setTitleColor(.white, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: key == "⌫" ? 20 : 27, weight: .regular)
                button.layer.cornerRadius = 4
                button.layer.borderWidth = 1
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 73).isActive = true
                button.layer.borderColor = UIColor(red: 0x3a/255.0, green: 0x3f/255.0, blue: 0x4a/255.0, alpha: 1).cgColor
                button.addTarget(self, action: #selector(tapKey(_:)), for: .touchUpInside)
                button.heightAnchor.constraint(equalToConstant: 52).isActive = true
                line.addArrangedSubview(button)
            }
            pad.addArrangedSubview(line)
        }

        forgotButton.setTitle("Forgot PIN? Reset the device cache", for: .normal)
        forgotButton.setTitleColor(UIColor(white: 0.55, alpha: 1), for: .normal)
        forgotButton.titleLabel?.font = .systemFont(ofSize: 12)
        forgotButton.addTarget(self, action: #selector(forgotPin), for: .touchUpInside)
        forgotButton.isHidden = mode == .setup

        let stack = UIStackView(arrangedSubviews: [title, message, dots, pad, forgotButton])
        stack.axis = .vertical
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let until = AppLock.shared.lockedUntil {
            message.text = "Too many attempts — try again at \(formatted(until))."
        }
    }

    // MARK: - Keypad

    @objc private func tapKey(_ sender: UIButton) {
        guard let key = sender.titleLabel?.text else { return }
        if key == "⌫" {
            if !pin.isEmpty { pin.removeLast() }
            dots.text = pinDots()
            return
        }
        guard pin.count < 4 else { return }
        pin.append(key)
        dots.text = pinDots()
        if pin.count == 4 { submit() }
    }

    private func submit() {
        switch mode {
        case .setup:
            if firstEntry == nil {
                firstEntry = pin
                pin = ""
                dots.text = pinDots()
                message.text = "Confirm the PIN."
                return
            }
            guard firstEntry == pin else {
                resetEntry("PINs did not match — start again.")
                return
            }
            do {
                try AppLock.shared.setPin(pin)
                onDone()
            } catch {
                resetEntry("Could not save the PIN on this device.")
            }

        case .unlock:
            do {
                if try AppLock.shared.unlock(pin: pin) {
                    onDone()
                } else {
                    resetEntry("Incorrect PIN.")
                }
            } catch {
                resetEntry(error.localizedDescription)
            }
        }
    }

    private func resetEntry(_ text: String) {
        pin = ""
        firstEntry = nil
        dots.text = pinDots()
        message.text = text
    }

    private func pinDots() -> String {
        String(repeating: "●", count: pin.count) + String(repeating: "○", count: max(0, 4 - pin.count))
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Forgot PIN

    @objc private func forgotPin() {
        let alert = UIAlertController(
            title: "Reset the device cache?",
            message: "The saved pages cannot be read without the PIN. Resetting deletes them and signs you out of the offline copy — you can sign in again over a connection.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            AppLock.shared.reset()
            self?.onDone()
        })
        present(alert, animated: true)
    }
}
