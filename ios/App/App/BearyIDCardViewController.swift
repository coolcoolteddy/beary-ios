import UIKit

// ===== 注册后引导 ID 卡：表单底 sheet ＋ 可翻转 ID 卡底 sheet =====
// 流程：进主页后约 400ms 弹表单（只弹一次）→「生成 ID 卡」/「跳过」380ms 后
// 弹 ID 卡。两张 sheet 都走系统底部 sheet（UISheetPresentationController，
// 见 BearySystemSheet），视觉按预览：白底卡片、系统抓手、顶圆角 26。
// 数据只存本地（见 BearyIDCard.swift 注释：服务端 display_name 有唯一性
// 校验且无生日/城市字段，本流程不调 profile 接口）。
// 部署目标 iOS 16.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

// MARK: - Form sheet

enum BearyIDCardFormSheet {

    static func show(from presenter: UIViewController, initialNickname: String, locatedCity: (country: String, region: String, city: String)?, onGenerate: @escaping (BearyIDCardData) -> Void, onSkip: @escaping (BearyIDCardData) -> Void, onDismissedWithoutChoice: @escaping () -> Void) {
        let sheet = BearyIDCardFormViewController(initialNickname: initialNickname, locatedCity: locatedCity)
        sheet.onGenerate = onGenerate
        sheet.onSkip = onSkip
        sheet.onDismissedWithoutChoice = onDismissedWithoutChoice
        BearySystemSheet.present(sheet, from: presenter)
    }
}

final class BearyIDCardFormViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, BearySystemSheetSizing {

    var onGenerate: ((BearyIDCardData) -> Void)?
    var onSkip: ((BearyIDCardData) -> Void)?
    var onDismissedWithoutChoice: (() -> Void)?

    private let initialNickname: String
    private let locatedCity: (country: String, region: String, city: String)?

    // 表单状态。
    private var birthdayMonth: Int?
    private var birthdayDay: Int?
    private var selectedCountry: String?
    private var selectedRegion: String?
    private var selectedCity: String?
    private var didChoose = false
    private var extraBottomInset: CGFloat = 0

    // 级联选择器状态。
    private var pickerLevel = 0 // 0 国家 / 1 地区 / 2 城市
    private var showingPicker = false

    // 视图。
    private let formScrollView = UIScrollView()
    private let formStack = UIStackView()
    private let pickerContainer = UIView()
    private let pickerTitleLabel = UILabel()
    private let pickerCrumbLabel = UILabel()
    private let pickerTableView = UITableView(frame: .zero, style: .plain)
    private var pickerTableHeightConstraint: NSLayoutConstraint?
    private let nicknameField = UITextField()
    private let birthdayField = UITextField()
    private let cityButton = UIButton(type: .custom)
    private let nicknameContainer = UIView()
    private let birthdayContainer = UIView()
    private let cityContainer = UIView()
    private let birthdayPicker = UIDatePicker()

    init(initialNickname: String, locatedCity: (country: String, region: String, city: String)?) {
        self.initialNickname = initialNickname
        self.locatedCity = locatedCity
        if let located = locatedCity {
            selectedCountry = located.country
            selectedRegion = located.region
            selectedCity = located.city
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.layer.cornerRadius = 26
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        buildForm()
        buildPicker()
        pickerContainer.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 拖走关闭＝未做选择（生成/跳过已置 didChoose，不会误报）。
        if !didChoose {
            didChoose = true
            onDismissedWithoutChoice?()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Form

    private func buildForm() {
        formScrollView.translatesAutoresizingMaskIntoConstraints = false
        formScrollView.showsVerticalScrollIndicator = false
        formScrollView.alwaysBounceVertical = false
        view.addSubview(formScrollView)
        NSLayoutConstraint.activate([
            formScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            formScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        formScrollView.addSubview(contentView)
        formStack.translatesAutoresizingMaskIntoConstraints = false
        formStack.axis = .vertical
        formStack.spacing = 14
        contentView.addSubview(formStack)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: formScrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: formScrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: formScrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: formScrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: formScrollView.frameLayoutGuide.widthAnchor),
            formStack.topAnchor.constraint(equalTo: contentView.topAnchor),
            formStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            formStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            formStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        // 系统 sheet 自带抓手（旧自绘抓手退役，留 15pt 顶距、标题位置不动）。
        formStack.addArrangedSubview(spacer(15))
        formStack.addArrangedSubview(spacer(8))
        // 标题＋说明。
        let titleLabel = UILabel()
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        titleLabel.font = .onboardingSerif(ofSize: 21)
        titleLabel.textColor = BearyOnboardingPalette.ink
        titleLabel.text = "完善你的 ID 卡"
        formStack.addArrangedSubview(titleLabel)
        let descLabel = UILabel()
        descLabel.numberOfLines = 0
        descLabel.textAlignment = .center
        descLabel.font = UIFont.systemFont(ofSize: 13)
        descLabel.textColor = BearyOnboardingPalette.muted
        descLabel.text = "这些信息会出现在你的 ID 卡背面"
        formStack.addArrangedSubview(descLabel)
        formStack.addArrangedSubview(spacer(6))
        // 昵称（占位「必填」，不做必填；空着点生成回退默认名 Teddy）。
        formStack.addArrangedSubview(makeFieldLabel("昵称"))
        configureTextFieldContainer(nicknameContainer)
        nicknameField.translatesAutoresizingMaskIntoConstraints = false
        nicknameField.font = UIFont.systemFont(ofSize: 16)
        nicknameField.textColor = BearyOnboardingPalette.ink
        nicknameField.text = initialNickname
        nicknameField.placeholder = "必填"
        nicknameField.returnKeyType = .done
        nicknameField.delegate = self
        nicknameField.clearButtonMode = .whileEditing
        nicknameContainer.addSubview(nicknameField)
        NSLayoutConstraint.activate([
            nicknameField.leadingAnchor.constraint(equalTo: nicknameContainer.leadingAnchor, constant: 12),
            nicknameField.trailingAnchor.constraint(equalTo: nicknameContainer.trailingAnchor, constant: -12),
            nicknameField.topAnchor.constraint(equalTo: nicknameContainer.topAnchor),
            nicknameField.bottomAnchor.constraint(equalTo: nicknameContainer.bottomAnchor),
        ])
        formStack.addArrangedSubview(nicknameContainer)
        // 生日（选填；聚焦变日期选择器，空着失焦仍为空）。
        formStack.addArrangedSubview(makeFieldLabel("生日"))
        configureTextFieldContainer(birthdayContainer)
        birthdayField.translatesAutoresizingMaskIntoConstraints = false
        birthdayField.font = UIFont.systemFont(ofSize: 16)
        birthdayField.textColor = BearyOnboardingPalette.ink
        birthdayField.placeholder = "选填"
        birthdayField.delegate = self
        birthdayPicker.datePickerMode = .date
        if #available(iOS 13.4, *) {
            birthdayPicker.preferredDatePickerStyle = .wheels
        }
        birthdayPicker.addTarget(self, action: #selector(birthdayPickerChanged(_:)), for: .valueChanged)
        birthdayField.inputView = birthdayPicker
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let doneItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(birthdayPickerDone))
        let flexibleItem = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        toolbar.items = [flexibleItem, doneItem]
        birthdayField.inputAccessoryView = toolbar
        birthdayContainer.addSubview(birthdayField)
        NSLayoutConstraint.activate([
            birthdayField.leadingAnchor.constraint(equalTo: birthdayContainer.leadingAnchor, constant: 12),
            birthdayField.trailingAnchor.constraint(equalTo: birthdayContainer.trailingAnchor, constant: -12),
            birthdayField.topAnchor.constraint(equalTo: birthdayContainer.topAnchor),
            birthdayField.bottomAnchor.constraint(equalTo: birthdayContainer.bottomAnchor),
        ])
        formStack.addArrangedSubview(birthdayContainer)
        // 城市（三级级联）。
        formStack.addArrangedSubview(makeFieldLabel("城市"))
        configureTextFieldContainer(cityContainer)
        cityButton.translatesAutoresizingMaskIntoConstraints = false
        cityButton.contentHorizontalAlignment = .left
        cityButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 28)
        cityButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        // 三级全名长时缩字不截尾（「中国 · 内蒙古自治区 · 锡林郭勒盟」）。
        cityButton.titleLabel?.adjustsFontSizeToFitWidth = true
        cityButton.titleLabel?.minimumScaleFactor = 0.7
        cityButton.addTarget(self, action: #selector(cityButtonTapped), for: .touchUpInside)
        cityContainer.addSubview(cityButton)
        let cityChevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        cityChevron.translatesAutoresizingMaskIntoConstraints = false
        cityChevron.tintColor = BearyOnboardingPalette.muted
        cityChevron.contentMode = .scaleAspectFit
        // chevron 不接手势：整行点按都落到按钮上。
        cityChevron.isUserInteractionEnabled = false
        cityContainer.addSubview(cityChevron)
        NSLayoutConstraint.activate([
            cityButton.leadingAnchor.constraint(equalTo: cityContainer.leadingAnchor),
            cityButton.trailingAnchor.constraint(equalTo: cityContainer.trailingAnchor),
            cityButton.topAnchor.constraint(equalTo: cityContainer.topAnchor),
            cityButton.bottomAnchor.constraint(equalTo: cityContainer.bottomAnchor),
            cityChevron.trailingAnchor.constraint(equalTo: cityContainer.trailingAnchor, constant: -12),
            cityChevron.centerYAnchor.constraint(equalTo: cityContainer.centerYAnchor),
            cityChevron.widthAnchor.constraint(equalToConstant: 14),
            cityChevron.heightAnchor.constraint(equalToConstant: 14),
        ])
        refreshCityButton()
        formStack.addArrangedSubview(cityContainer)
        formStack.addArrangedSubview(spacer(6))
        // 生成＋跳过。
        let generateButton = makeSheetBlackButton(title: "生成 ID 卡")
        generateButton.addTarget(self, action: #selector(generateTapped), for: .touchUpInside)
        formStack.addArrangedSubview(generateButton)
        let skipButton = UIButton(type: .system)
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        skipButton.setTitle("跳过", for: .normal)
        skipButton.setTitleColor(BearyOnboardingPalette.ink, for: .normal)
        skipButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        skipButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        skipButton.addTarget(self, action: #selector(skipFormTapped), for: .touchUpInside)
        formStack.addArrangedSubview(skipButton)
        formStack.addArrangedSubview(spacer(20))
    }

    private func makeFieldLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = BearyOnboardingPalette.ink2
        label.text = text
        return label
    }

    private func configureTextFieldContainer(_ container: UIView) {
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = .white
        container.layer.borderColor = BearyOnboardingPalette.line.cgColor
        container.layer.borderWidth = 1
        container.layer.cornerRadius = 12
        container.heightAnchor.constraint(equalToConstant: 50).isActive = true
    }

    private func spacer(_ height: CGFloat) -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func makeSheetBlackButton(title: String) -> UIButton {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = BearyOnboardingPalette.ink
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = BearyDynamicType.buttonFont()
        button.setTitle(title, for: .normal)
        button.layer.cornerRadius = 12
        button.heightAnchor.constraint(equalToConstant: 52).isActive = true
        button.addTarget(self, action: #selector(sheetButtonTouchDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(sheetButtonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return button
    }

    @objc private func sheetButtonTouchDown(_ sender: UIButton) {
        UIView.animate(withDuration: BearyMotion.micro) { sender.alpha = 0.7 }
    }

    @objc private func sheetButtonTouchUp(_ sender: UIButton) {
        UIView.animate(withDuration: BearyMotion.micro) { sender.alpha = 1.0 }
    }

    private func refreshCityButton() {
        if let country = selectedCountry, let region = selectedRegion, let city = selectedCity {
            cityButton.setTitle("\(country) · \(region) · \(city)", for: .normal)
            cityButton.setTitleColor(BearyOnboardingPalette.ink, for: .normal)
        } else {
            cityButton.setTitle("请选择", for: .normal)
            cityButton.setTitleColor(BearyOnboardingPalette.faint, for: .normal)
        }
    }

    @objc private func generateTapped() {
        guard !didChoose else { return }
        didChoose = true
        let nickname = nicknameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolved = nickname.isEmpty ? "Teddy" : nickname
        let data = BearyIDCardData(nickname: resolved, birthdayMonth: birthdayMonth, birthdayDay: birthdayDay, country: selectedCountry, region: selectedRegion, city: selectedCity)
        onGenerate?(data)
        dismiss(animated: BearyMotion.animated(true))
    }

    @objc private func skipFormTapped() {
        guard !didChoose else { return }
        didChoose = true
        let data = BearyIDCardData(nickname: initialNickname, birthdayMonth: nil, birthdayDay: nil, country: nil, region: nil, city: nil)
        onSkip?(data)
        dismiss(animated: BearyMotion.animated(true))
    }

    // MARK: - Birthday picker

    @objc private func birthdayPickerChanged(_ sender: UIDatePicker) {
        let components = Calendar.current.dateComponents([.month, .day], from: sender.date)
        birthdayMonth = components.month
        birthdayDay = components.day
        if let month = birthdayMonth, let day = birthdayDay {
            // 2026-11-21 日期完全本地化：中文沿用“X月X日”，非中文走共享 helper。
            birthdayField.text = BearyLocalizedDate.monthDayString(month: month, day: day)
        }
    }

    @objc private func birthdayPickerDone() {
        birthdayField.resignFirstResponder()
    }

    // MARK: - UITextFieldDelegate

    func textFieldDidBeginEditing(_ textField: UITextField) {
        if textField == nicknameField {
            nicknameContainer.layer.borderColor = BearyOnboardingPalette.ink.cgColor
        } else if textField == birthdayField {
            birthdayContainer.layer.borderColor = BearyOnboardingPalette.ink.cgColor
            // 已有生日时选择器先指到该日；没选过时保持系统默认（今天）。
            if let month = birthdayMonth, let day = birthdayDay {
                var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                components.month = month
                components.day = day
                if let date = Calendar.current.date(from: components) {
                    birthdayPicker.date = date
                }
            }
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        if textField == nicknameField {
            nicknameContainer.layer.borderColor = BearyOnboardingPalette.line.cgColor
        } else if textField == birthdayField {
            birthdayContainer.layer.borderColor = BearyOnboardingPalette.line.cgColor
            // 没选过日期时字段仍为空（占位「选填」），不回填默认日期。
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    // MARK: - Keyboard

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let keyboardFrame = frameValue.cgRectValue
        let keyboardHeight = view.convert(keyboardFrame, from: nil).height
        let bottomInset = max(0, keyboardHeight - view.safeAreaInsets.bottom)
        formScrollView.contentInset.bottom = bottomInset
        formScrollView.scrollIndicatorInsets.bottom = bottomInset
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        formScrollView.contentInset.bottom = 0
        formScrollView.scrollIndicatorInsets.bottom = 0
    }

    // MARK: - City cascade picker

    private func buildPicker() {
        pickerContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pickerContainer)
        NSLayoutConstraint.activate([
            pickerContainer.topAnchor.constraint(equalTo: view.topAnchor),
            pickerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pickerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pickerContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // 返回。
        let backButton = UIButton(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = BearyOnboardingPalette.ink
        backButton.addTarget(self, action: #selector(pickerBackTapped), for: .touchUpInside)
        backButton.accessibilityLabel = "返回"
        pickerContainer.addSubview(backButton)
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: pickerContainer.leadingAnchor, constant: 8),
            backButton.topAnchor.constraint(equalTo: pickerContainer.topAnchor, constant: 22),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        // 标题＋面包屑。
        pickerTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        pickerTitleLabel.font = .onboardingSerif(ofSize: 19, weight: .bold)
        pickerTitleLabel.textColor = BearyOnboardingPalette.ink
        pickerTitleLabel.textAlignment = .center
        pickerContainer.addSubview(pickerTitleLabel)
        pickerCrumbLabel.translatesAutoresizingMaskIntoConstraints = false
        pickerCrumbLabel.font = UIFont.systemFont(ofSize: 12)
        pickerCrumbLabel.textColor = BearyOnboardingPalette.muted
        pickerCrumbLabel.textAlignment = .center
        pickerContainer.addSubview(pickerCrumbLabel)
        NSLayoutConstraint.activate([
            pickerTitleLabel.topAnchor.constraint(equalTo: pickerContainer.topAnchor, constant: 28),
            pickerTitleLabel.centerXAnchor.constraint(equalTo: pickerContainer.centerXAnchor),
            pickerCrumbLabel.topAnchor.constraint(equalTo: pickerTitleLabel.bottomAnchor, constant: 4),
            pickerCrumbLabel.centerXAnchor.constraint(equalTo: pickerContainer.centerXAnchor),
            pickerCrumbLabel.leadingAnchor.constraint(greaterThanOrEqualTo: pickerContainer.leadingAnchor, constant: 60),
            pickerCrumbLabel.trailingAnchor.constraint(lessThanOrEqualTo: pickerContainer.trailingAnchor, constant: -60),
        ])
        // 列表（最高 46vh，可滚动）。
        pickerTableView.translatesAutoresizingMaskIntoConstraints = false
        pickerTableView.dataSource = self
        pickerTableView.delegate = self
        pickerTableView.rowHeight = 50
        pickerTableView.separatorColor = BearyOnboardingPalette.line2
        pickerTableView.separatorInset = .zero
        pickerTableView.showsVerticalScrollIndicator = false
        pickerTableView.register(UITableViewCell.self, forCellReuseIdentifier: "BearyCityPickerCell")
        pickerContainer.addSubview(pickerTableView)
        let tableHeight = NSLayoutConstraint(item: pickerTableView, attribute: .height, relatedBy: .equal, toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 200)
        pickerTableHeightConstraint = tableHeight
        NSLayoutConstraint.activate([
            pickerTableView.topAnchor.constraint(equalTo: pickerCrumbLabel.bottomAnchor, constant: 16),
            pickerTableView.leadingAnchor.constraint(equalTo: pickerContainer.leadingAnchor, constant: 24),
            pickerTableView.trailingAnchor.constraint(equalTo: pickerContainer.trailingAnchor, constant: -24),
            pickerTableView.bottomAnchor.constraint(lessThanOrEqualTo: pickerContainer.bottomAnchor, constant: -20),
            tableHeight,
        ])
    }

    @objc private func cityButtonTapped() {
        view.endEditing(true)
        pickerLevel = 0
        showPicker(true)
    }

    @objc private func pickerBackTapped() {
        if pickerLevel == 0 {
            showPicker(false)
        } else {
            pickerLevel -= 1
            refreshPicker()
        }
    }

    private func showPicker(_ show: Bool) {
        showingPicker = show
        if show {
            refreshPicker()
            pickerContainer.isHidden = false
            pickerContainer.alpha = 0
            formScrollView.alpha = 1
        } else {
            formScrollView.isHidden = false
            formScrollView.alpha = 0
            pickerContainer.alpha = 1
        }
        let duration = BearyMotion.animated(true) ? BearyMotion.micro : 0
        UIView.animate(withDuration: duration, animations: {
            self.formScrollView.alpha = show ? 0 : 1
            self.pickerContainer.alpha = show ? 1 : 0
        }, completion: { _ in
            self.formScrollView.isHidden = show
            self.pickerContainer.isHidden = !show
            self.formScrollView.alpha = 1
            self.pickerContainer.alpha = 1
        })
        updatePreferredContentSize(extraBottomInset: extraBottomInset)
    }

    private func pickerRows() -> [String] {
        switch pickerLevel {
        case 0:
            return BearyCityData.countries.map { $0.name }
        case 1:
            guard let countryName = selectedCountry else { return [] }
            guard let country = BearyCityData.countries.first(where: { $0.name == countryName }) else { return [] }
            return country.regions.map { $0.name }
        default:
            guard let countryName = selectedCountry, let regionName = selectedRegion else { return [] }
            guard let country = BearyCityData.countries.first(where: { $0.name == countryName }) else { return [] }
            guard let region = country.regions.first(where: { $0.name == regionName }) else { return [] }
            return region.cities
        }
    }

    private func pickerCurrentSelection() -> String? {
        switch pickerLevel {
        case 0: return selectedCountry
        case 1: return selectedRegion
        default: return selectedCity
        }
    }

    private func refreshPicker() {
        switch pickerLevel {
        case 0:
            pickerTitleLabel.text = "选择国家"
            pickerCrumbLabel.text = ""
        case 1:
            pickerTitleLabel.text = "选择地区"
            pickerCrumbLabel.text = selectedCountry ?? ""
        default:
            pickerTitleLabel.text = "选择城市"
            if let country = selectedCountry, let region = selectedRegion {
                pickerCrumbLabel.text = "\(country) · \(region)"
            } else {
                pickerCrumbLabel.text = ""
            }
        }
        let rows = pickerRows()
        let maxListHeight = UIScreen.main.bounds.height * 0.46
        let listHeight = min(CGFloat(rows.count) * 50, maxListHeight)
        pickerTableHeightConstraint?.constant = max(listHeight, 50)
        pickerTableView.reloadData()
        pickerTableView.setContentOffset(.zero, animated: false)
        updatePreferredContentSize(extraBottomInset: extraBottomInset)
    }

    // MARK: - UITableViewDataSource / Delegate

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return pickerRows().count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BearyCityPickerCell", for: indexPath)
        let rows = pickerRows()
        guard indexPath.row < rows.count else { return cell }
        let name = rows[indexPath.row]
        cell.textLabel?.font = UIFont.systemFont(ofSize: 16)
        cell.textLabel?.textColor = BearyOnboardingPalette.ink
        cell.textLabel?.text = name
        cell.backgroundColor = .white
        cell.selectionStyle = .none
        let isCurrent = pickerCurrentSelection() == name
        if isCurrent {
            let checkImage = UIImageView(image: UIImage(systemName: "checkmark"))
            checkImage.tintColor = BearyOnboardingPalette.orange
            checkImage.contentMode = .scaleAspectFit
            checkImage.translatesAutoresizingMaskIntoConstraints = false
            checkImage.widthAnchor.constraint(equalToConstant: 18).isActive = true
            checkImage.heightAnchor.constraint(equalToConstant: 18).isActive = true
            cell.accessoryView = checkImage
        } else if pickerLevel < 2 {
            let chevronImage = UIImageView(image: UIImage(systemName: "chevron.right"))
            chevronImage.tintColor = BearyOnboardingPalette.muted
            chevronImage.contentMode = .scaleAspectFit
            chevronImage.translatesAutoresizingMaskIntoConstraints = false
            chevronImage.widthAnchor.constraint(equalToConstant: 14).isActive = true
            chevronImage.heightAnchor.constraint(equalToConstant: 14).isActive = true
            cell.accessoryView = chevronImage
        } else {
            cell.accessoryView = nil
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        let rows = pickerRows()
        guard indexPath.row < rows.count else { return }
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressDown(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressUp(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let rows = pickerRows()
        guard indexPath.row < rows.count else { return }
        let name = rows[indexPath.row]
        switch pickerLevel {
        case 0:
            selectedCountry = name
            selectedRegion = nil
            selectedCity = nil
            pickerLevel = 1
            refreshPicker()
        case 1:
            selectedRegion = name
            selectedCity = nil
            pickerLevel = 2
            refreshPicker()
        default:
            selectedCity = name
            refreshCityButton()
            showPicker(false)
        }
    }

    // MARK: - Sizing

    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        self.extraBottomInset = extraBottomInset
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let contentHeight: CGFloat
        if showingPicker {
            // 列表实测高＋底边距（不用手算：标题/面包屑行高随字号走）。
            contentHeight = pickerTableView.frame.maxY + 20
        } else {
            contentHeight = formScrollView.contentSize.height
        }
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let preferred = CGSize(width: width, height: contentHeight + extraBottomInset)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
            BearySystemSheet.refreshDetentsIfNeeded(for: self)
        }
    }
}

// MARK: - ID card sheet

enum BearyIDCardSheet {

    static func show(from presenter: UIViewController, cardData: BearyIDCardData, stats: BearyIDCardStore.Stats, isPlus: Bool, avatarURL: URL?, serialText: String?, onDismissed: @escaping () -> Void) {
        let sheet = BearyIDCardSheetViewController(cardData: cardData, stats: stats, isPlus: isPlus, avatarURL: avatarURL, serialText: serialText)
        sheet.onDismissed = onDismissed
        BearySystemSheet.present(sheet, from: presenter)
    }
}

final class BearyIDCardSheetViewController: UIViewController, BearySystemSheetSizing {

    var onDismissed: (() -> Void)?

    private let cardData: BearyIDCardData
    private let stats: BearyIDCardStore.Stats
    private let isPlus: Bool
    private let avatarURL: URL?
    private let serialText: String?
    private var didCallDismissed = false
    private var extraBottomInset: CGFloat = 0

    private let scrollView = UIScrollView()
    private let cardView = BearyIDCardView()
    private let plusSwitch = UISwitch()

    init(cardData: BearyIDCardData, stats: BearyIDCardStore.Stats, isPlus: Bool, avatarURL: URL?, serialText: String?) {
        self.cardData = cardData
        self.stats = stats
        self.isPlus = isPlus
        self.avatarURL = avatarURL
        self.serialText = serialText
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.layer.cornerRadius = 26
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        buildContent()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !didCallDismissed {
            didCallDismissed = true
            onDismissed?()
        }
    }

    private func buildContent() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 20
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        // 系统 sheet 自带抓手（旧自绘抓手退役，留 15pt 顶距、卡片位置不动）。
        stack.addArrangedSubview(spacerView(15))
        // 卡片（点按绕 Y 轴翻转）。
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.configure(data: cardData, stats: stats, isPlus: isPlus, avatarURL: avatarURL, serialText: serialText)
        cardView.heightAnchor.constraint(equalTo: cardView.widthAnchor, multiplier: 1.0 / 1.586).isActive = true
        let cardTap = UITapGestureRecognizer(target: self, action: #selector(cardTapped))
        cardView.addGestureRecognizer(cardTap)
        cardView.bearyAddRowPressFeedback()
        stack.addArrangedSubview(cardView)
        // Plus 身份预览开关（默认关；开只预览皇冠，不开通 Plus）。
        let plusRow = UIStackView()
        plusRow.axis = .horizontal
        plusRow.alignment = .center
        plusRow.spacing = 8
        let plusTitle = UILabel()
        plusTitle.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        plusTitle.textColor = BearyOnboardingPalette.ink
        plusTitle.text = "Plus 身份"
        plusRow.addArrangedSubview(plusTitle)
        let plusNote = UILabel()
        plusNote.font = UIFont.systemFont(ofSize: 11.5)
        plusNote.textColor = BearyOnboardingPalette.faint
        plusNote.text = "预览开关"
        plusRow.addArrangedSubview(plusNote)
        let plusSpacer = UIView()
        plusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        plusRow.addArrangedSubview(plusSpacer)
        plusSwitch.translatesAutoresizingMaskIntoConstraints = false
        plusSwitch.onTintColor = UIColor(red: 52.0 / 255.0, green: 199.0 / 255.0, blue: 89.0 / 255.0, alpha: 1)
        plusSwitch.isOn = false
        plusSwitch.addTarget(self, action: #selector(plusSwitchChanged(_:)), for: .valueChanged)
        plusRow.addArrangedSubview(plusSwitch)
        stack.addArrangedSubview(plusRow)
        // 保存至相册＋以后再说。
        let saveButton = UIButton(type: .custom)
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.backgroundColor = BearyOnboardingPalette.ink
        saveButton.setTitleColor(.white, for: .normal)
        saveButton.titleLabel?.font = BearyDynamicType.buttonFont()
        saveButton.setTitle("保存至相册", for: .normal)
        saveButton.layer.cornerRadius = 12
        saveButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        stack.addArrangedSubview(saveButton)
        let laterButton = UIButton(type: .system)
        laterButton.translatesAutoresizingMaskIntoConstraints = false
        laterButton.setTitle("以后再说", for: .normal)
        laterButton.setTitleColor(BearyOnboardingPalette.ink, for: .normal)
        laterButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        laterButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        laterButton.addTarget(self, action: #selector(laterTapped), for: .touchUpInside)
        stack.addArrangedSubview(laterButton)
        stack.addArrangedSubview(spacerView(4))
    }

    private func spacerView(_ height: CGFloat) -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    @objc private func cardTapped() {
        cardView.flip(animated: true)
    }

    @objc private func plusSwitchChanged(_ sender: UISwitch) {
        cardView.setPlusPreview(sender.isOn)
    }

    @objc private func saveTapped() {
        let faceView = cardView.visibleFaceView()
        let savedTransform = faceView.layer.transform
        if cardView.isShowingBack {
            // 背面自带绕 Y 轴 180° 的预旋转，直接画会镜像：先归零再画。
            faceView.layer.transform = CATransform3DIdentity
        }
        // 存图用 3x 渲染（屏上卡片只有约 272×171pt，默认倍率存出来才约 800×500px）。
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: faceView.bounds.size, format: format)
        let image = renderer.image { _ in
            faceView.drawHierarchy(in: faceView.bounds, afterScreenUpdates: true)
        }
        if cardView.isShowingBack {
            faceView.layer.transform = savedTransform
        }
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(saveCompleted(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc private func saveCompleted(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        if error == nil {
            BearyToast.show(in: view, message: "已保存至相册")
        } else {
            BearyToast.show(in: view, message: "保存失败，请在设置中允许访问相册")
        }
    }

    @objc private func laterTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }

    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        self.extraBottomInset = extraBottomInset
        view.setNeedsLayout()
        view.layoutIfNeeded()
        let contentHeight = scrollView.contentSize.height
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let preferred = CGSize(width: width, height: contentHeight + extraBottomInset)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
            BearySystemSheet.refreshDetentsIfNeeded(for: self)
        }
    }
}

// MARK: - Flippable ID card

final class BearyIDCardView: UIView {

    private(set) var isShowingBack = false

    private let flipContainer = UIView()
    private let frontView = UIView()
    private let backView = UIView()
    private var plusBadge: UIView?
    private var plusBadgeVisible = false
    private var isPlus = false
    private var plusPreviewOn = false
    private var avatarPhotoView: UIImageView?
    private var avatarGlyphView: UIImageView?
    private var compact = false
    /// configure 的入参存一份：layoutSubviews 里 compact 翻面时重建卡片用（M10）。
    private var configuredData: BearyIDCardData?
    private var configuredStats: BearyIDCardStore.Stats?
    private var configuredAvatarURL: URL?
    private var configuredSerialText: String?
    /// 翻转进行中：连点两次不叠加动画（面与点按次数对不上）。
    private var isFlipping = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 16
        clipsToBounds = true
        layer.borderColor = BearyOnboardingPalette.line.cgColor
        layer.borderWidth = 1
        flipContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(flipContainer)
        NSLayoutConstraint.activate([
            flipContainer.topAnchor.constraint(equalTo: topAnchor),
            flipContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            flipContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            flipContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        frontView.translatesAutoresizingMaskIntoConstraints = false
        frontView.backgroundColor = .white
        frontView.layer.isDoubleSided = false
        flipContainer.addSubview(frontView)
        backView.translatesAutoresizingMaskIntoConstraints = false
        backView.backgroundColor = .white
        backView.layer.isDoubleSided = false
        // 背面预旋转 180°：容器转 180° 后背面正对观众。
        backView.layer.transform = CATransform3DMakeRotation(CGFloat.pi, 0, 1, 0)
        // 初始只显示正面：静止态的可见面由 isHidden 钉死（见 flip）。
        backView.isHidden = true
        flipContainer.addSubview(backView)
        NSLayoutConstraint.activate([
            frontView.topAnchor.constraint(equalTo: flipContainer.topAnchor),
            frontView.leadingAnchor.constraint(equalTo: flipContainer.leadingAnchor),
            frontView.trailingAnchor.constraint(equalTo: flipContainer.trailingAnchor),
            frontView.bottomAnchor.constraint(equalTo: flipContainer.bottomAnchor),
            backView.topAnchor.constraint(equalTo: flipContainer.topAnchor),
            backView.leadingAnchor.constraint(equalTo: flipContainer.leadingAnchor),
            backView.trailingAnchor.constraint(equalTo: flipContainer.trailingAnchor),
            backView.bottomAnchor.constraint(equalTo: flipContainer.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(data: BearyIDCardData, stats: BearyIDCardStore.Stats, isPlus: Bool, avatarURL: URL?, serialText: String?) {
        self.isPlus = isPlus
        configuredData = data
        configuredStats = stats
        configuredAvatarURL = avatarURL
        configuredSerialText = serialText
        // 窄屏卡片收紧内距（320 宽机型仍须装下背面全部内容）。
        compact = bounds.width > 0 ? bounds.width < 340 : UIScreen.main.bounds.width < 388
        buildFront()
        buildBack(data: data, stats: stats, avatarURL: avatarURL, serialText: serialText)
        updatePlusBadge()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // M10：实际宽度定下来后再定 compact——configure 时 bounds 还是 0
        //（屏幕宽回退在 iPad 分屏里判错），旋转／分屏变宽后也要重算。
        guard bounds.width > 0 else { return }
        let newCompact = bounds.width < 340
        guard newCompact != compact, let data = configuredData, let stats = configuredStats else { return }
        compact = newCompact
        buildFront()
        buildBack(data: data, stats: stats, avatarURL: configuredAvatarURL, serialText: configuredSerialText)
        updatePlusBadge()
    }

    func setPlusPreview(_ on: Bool) {
        plusPreviewOn = on
        updatePlusBadge()
    }

    private func updatePlusBadge() {
        let show = isPlus || plusPreviewOn
        plusBadgeVisible = show
        plusBadge?.isHidden = !show
    }

    /// 点卡片绕 Y 轴 0.55s 弹簧翻转；减动效时直接换面。
    /// 静止态只靠 isDoubleSided=false 兜底，真机上背面会显示正面的镜像：
    /// 翻转完成后用 isHidden 钉死只显示当前面。动画开始前两面先都显示，
    /// 让出去的面能正常转走（否则翻面中途卡片会变空）。
    func flip(animated: Bool) {
        guard !isFlipping else { return }
        isShowingBack.toggle()
        let target: CGFloat = isShowingBack ? CGFloat.pi : 0
        let applyTransform = {
            var transform = CATransform3DIdentity
            transform.m34 = -1.0 / 1200.0
            transform = CATransform3DRotate(transform, target, 0, 1, 0)
            self.flipContainer.layer.transform = transform
        }
        let applyVisibility = { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.frontView.isHidden = strongSelf.isShowingBack
            strongSelf.backView.isHidden = !strongSelf.isShowingBack
        }
        if animated && BearyMotion.animated(true) {
            isFlipping = true
            frontView.isHidden = false
            backView.isHidden = false
            UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [], animations: applyTransform, completion: { [weak self] _ in
                self?.isFlipping = false
                applyVisibility()
            })
        } else {
            applyTransform()
            applyVisibility()
        }
    }

    func visibleFaceView() -> UIView {
        return isShowingBack ? backView : frontView
    }

    // MARK: - Front（干净纯白：logo 行＋标语＋翻转提示）

    private func buildFront() {
        // 重建先清旧子视图（layoutSubviews 里 compact 翻面时重建，见 M10）。
        frontView.subviews.forEach { $0.removeFromSuperview() }
        // 顶行：横版 logo 19 高＋「ID」。
        let topRow = UIStackView()
        topRow.translatesAutoresizingMaskIntoConstraints = false
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 6
        let logoImage = UIImageView(image: UIImage(named: BearyAssets.logoHorizontal))
        logoImage.contentMode = .scaleAspectFit
        logoImage.translatesAutoresizingMaskIntoConstraints = false
        logoImage.heightAnchor.constraint(equalToConstant: 19).isActive = true
        // 只定高不定宽时帧是原图内在宽（@2x 155pt／@3x 103pt），图在框里留白、
        // 「ID」偏移随倍率变——按原图宽高比定宽，框即图。
        if let logo = logoImage.image {
            logoImage.widthAnchor.constraint(equalTo: logoImage.heightAnchor, multiplier: logo.size.width / logo.size.height).isActive = true
        }
        topRow.addArrangedSubview(logoImage)
        let idLabel = UILabel()
        idLabel.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        idLabel.textColor = BearyOnboardingPalette.ink
        idLabel.text = "ID"
        topRow.addArrangedSubview(idLabel)
        frontView.addSubview(topRow)
        NSLayoutConstraint.activate([
            topRow.topAnchor.constraint(equalTo: frontView.topAnchor, constant: 16),
            topRow.leadingAnchor.constraint(equalTo: frontView.leadingAnchor, constant: 18),
        ])
        // 标语（衬线、居中）。
        let sloganLabel = UILabel()
        sloganLabel.translatesAutoresizingMaskIntoConstraints = false
        sloganLabel.font = .onboardingSerif(ofSize: 12)
        sloganLabel.textColor = BearyOnboardingPalette.muted
        sloganLabel.textAlignment = .center
        let sloganText = NSMutableAttributedString(string: "日子值得记得")
        sloganText.addAttribute(.kern, value: 12.0 * 0.14, range: NSRange(location: 0, length: sloganText.length))
        sloganLabel.attributedText = sloganText
        frontView.addSubview(sloganLabel)
        NSLayoutConstraint.activate([
            sloganLabel.centerXAnchor.constraint(equalTo: frontView.centerXAnchor),
            sloganLabel.centerYAnchor.constraint(equalTo: frontView.centerYAnchor),
        ])
        // 底部提示：点一下，翻到背面。
        let hintRow = UIStackView()
        hintRow.translatesAutoresizingMaskIntoConstraints = false
        hintRow.axis = .horizontal
        hintRow.alignment = .center
        hintRow.spacing = 6
        let flipIcon = UIImageView(image: UIImage(systemName: "arrow.triangle.2.circlepath"))
        flipIcon.tintColor = BearyOnboardingPalette.muted
        flipIcon.contentMode = .scaleAspectFit
        flipIcon.translatesAutoresizingMaskIntoConstraints = false
        flipIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        flipIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        hintRow.addArrangedSubview(flipIcon)
        let hintLabel = UILabel()
        hintLabel.font = UIFont.systemFont(ofSize: 13)
        hintLabel.textColor = BearyOnboardingPalette.muted
        hintLabel.text = "点一下，翻到背面"
        hintRow.addArrangedSubview(hintLabel)
        frontView.addSubview(hintRow)
        NSLayoutConstraint.activate([
            hintRow.centerXAnchor.constraint(equalTo: frontView.centerXAnchor),
            hintRow.bottomAnchor.constraint(equalTo: frontView.bottomAnchor, constant: -14),
        ])
    }

    // MARK: - Back（分段：黑带＋名字＋明细＋统计）

    private func buildBack(data: BearyIDCardData, stats: BearyIDCardStore.Stats, avatarURL: URL?, serialText: String?) {
        // 重建先清旧子视图（layoutSubviews 里 compact 翻面时重建，见 M10）。
        backView.subviews.forEach { $0.removeFromSuperview() }
        let bandHeight: CGFloat = compact ? 35 : 39
        let avatarDiameter: CGFloat = compact ? 36 : 46
        let bodyGap: CGFloat = compact ? 5 : 8
        // 黑带：白 logo 21 高＋「ID」，右端卡号（真值，见 M6）。
        let band = UIView()
        band.translatesAutoresizingMaskIntoConstraints = false
        band.backgroundColor = .black
        backView.addSubview(band)
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: backView.topAnchor),
            band.leadingAnchor.constraint(equalTo: backView.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: backView.trailingAnchor),
            band.heightAnchor.constraint(equalToConstant: bandHeight),
        ])
        let bandRow = UIStackView()
        bandRow.translatesAutoresizingMaskIntoConstraints = false
        bandRow.axis = .horizontal
        bandRow.alignment = .center
        bandRow.spacing = 6
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)
        let whiteLogo = UIImage(named: BearyAssets.logoHorizontal, in: nil, compatibleWith: darkTraits)
        let bandLogo = UIImageView(image: whiteLogo)
        bandLogo.contentMode = .scaleAspectFit
        bandLogo.translatesAutoresizingMaskIntoConstraints = false
        bandLogo.heightAnchor.constraint(equalToConstant: 21).isActive = true
        // 同正面：按原图宽高比定宽，框即图（只定高时帧是内在宽，留白且偏移随倍率变）。
        if let logo = bandLogo.image {
            bandLogo.widthAnchor.constraint(equalTo: bandLogo.heightAnchor, multiplier: logo.size.width / logo.size.height).isActive = true
        }
        bandRow.addArrangedSubview(bandLogo)
        let bandIDLabel = UILabel()
        bandIDLabel.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        bandIDLabel.textColor = .white
        bandIDLabel.text = "ID"
        bandRow.addArrangedSubview(bandIDLabel)
        band.addSubview(bandRow)
        let numberLabel = UILabel()
        numberLabel.translatesAutoresizingMaskIntoConstraints = false
        numberLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        numberLabel.textColor = UIColor(white: 1, alpha: 0.75)
        // M6：卡号用真值（serial_id／@handle／数字 id，见 SceneDelegate），
        // 没有真值时不显示这一行，不编造。
        if let serialText = serialText {
            numberLabel.text = "№ \(serialText)"
        } else {
            numberLabel.isHidden = true
        }
        band.addSubview(numberLabel)
        NSLayoutConstraint.activate([
            bandRow.leadingAnchor.constraint(equalTo: band.leadingAnchor, constant: 16),
            bandRow.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            numberLabel.trailingAnchor.constraint(equalTo: band.trailingAnchor, constant: -16),
            numberLabel.centerYAnchor.constraint(equalTo: band.centerYAnchor),
        ])
        // 头像＋名字行。
        let avatarCircle = UIView()
        avatarCircle.translatesAutoresizingMaskIntoConstraints = false
        avatarCircle.backgroundColor = BearyOnboardingPalette.blueSoft
        avatarCircle.layer.cornerRadius = avatarDiameter / 2
        avatarCircle.clipsToBounds = true
        backView.addSubview(avatarCircle)
        NSLayoutConstraint.activate([
            avatarCircle.topAnchor.constraint(equalTo: band.bottomAnchor, constant: compact ? 8 : 11),
            avatarCircle.leadingAnchor.constraint(equalTo: backView.leadingAnchor, constant: 16),
            avatarCircle.widthAnchor.constraint(equalToConstant: avatarDiameter),
            avatarCircle.heightAnchor.constraint(equalToConstant: avatarDiameter),
        ])
        let glyphView = UIImageView(image: UIImage(systemName: "person.fill"))
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        glyphView.tintColor = BearyOnboardingPalette.muted
        glyphView.contentMode = .scaleAspectFit
        avatarCircle.addSubview(glyphView)
        NSLayoutConstraint.activate([
            glyphView.centerXAnchor.constraint(equalTo: avatarCircle.centerXAnchor),
            glyphView.centerYAnchor.constraint(equalTo: avatarCircle.centerYAnchor),
            glyphView.widthAnchor.constraint(equalToConstant: avatarDiameter * 0.52),
            glyphView.heightAnchor.constraint(equalToConstant: avatarDiameter * 0.52),
        ])
        avatarGlyphView = glyphView
        let photoView = UIImageView()
        photoView.translatesAutoresizingMaskIntoConstraints = false
        photoView.contentMode = .scaleAspectFill
        photoView.isHidden = true
        avatarCircle.addSubview(photoView)
        NSLayoutConstraint.activate([
            photoView.topAnchor.constraint(equalTo: avatarCircle.topAnchor),
            photoView.leadingAnchor.constraint(equalTo: avatarCircle.leadingAnchor),
            photoView.trailingAnchor.constraint(equalTo: avatarCircle.trailingAnchor),
            photoView.bottomAnchor.constraint(equalTo: avatarCircle.bottomAnchor),
        ])
        avatarPhotoView = photoView
        if let avatarURLValue = avatarURL {
            loadAvatar(url: avatarURLValue)
        }
        // 名字＋皇冠＋「今天加入 beary」。
        let nameStack = UIStackView()
        nameStack.translatesAutoresizingMaskIntoConstraints = false
        nameStack.axis = .vertical
        nameStack.spacing = 2
        backView.addSubview(nameStack)
        NSLayoutConstraint.activate([
            nameStack.leadingAnchor.constraint(equalTo: avatarCircle.trailingAnchor, constant: 12),
            nameStack.trailingAnchor.constraint(lessThanOrEqualTo: backView.trailingAnchor, constant: -16),
            nameStack.centerYAnchor.constraint(equalTo: avatarCircle.centerYAnchor),
        ])
        let nameRow = UIStackView()
        nameRow.axis = .horizontal
        nameRow.alignment = .center
        nameRow.spacing = 6
        let nameLabel = UILabel()
        nameLabel.font = UIFont.systemFont(ofSize: 19, weight: .bold)
        nameLabel.textColor = BearyOnboardingPalette.ink
        nameLabel.text = data.nickname
        // 长昵称不顶皇冠：先缩字，缩到头再截尾。
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.7
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameRow.addArrangedSubview(nameLabel)
        let badge = makePlusBadge()
        plusBadge = badge
        nameRow.addArrangedSubview(badge)
        nameStack.addArrangedSubview(nameRow)
        let joinedLabel = UILabel()
        joinedLabel.font = UIFont.systemFont(ofSize: 11.5, weight: .semibold)
        joinedLabel.textColor = UIColor(red: 199.0 / 255.0, green: 116.0 / 255.0, blue: 0.0 / 255.0, alpha: 1)
        // 注册当天才说「今天加入」；冷启动补弹时可能已是几天后，改说加入日期。
        joinedLabel.text = stats.joinDays == 1 ? "今天加入 beary" : "加入于 \(stats.sinceText)"
        nameStack.addArrangedSubview(joinedLabel)
        // 明细格（生日只月日／城市只城市名／SINCE；没填的不显示）。
        let detailsContainer = UIView()
        detailsContainer.translatesAutoresizingMaskIntoConstraints = false
        backView.addSubview(detailsContainer)
        NSLayoutConstraint.activate([
            detailsContainer.topAnchor.constraint(equalTo: avatarCircle.bottomAnchor, constant: bodyGap + 5),
            detailsContainer.leadingAnchor.constraint(equalTo: backView.leadingAnchor, constant: 16),
            detailsContainer.trailingAnchor.constraint(equalTo: backView.trailingAnchor, constant: -16),
        ])
        let detailsHairline = UIView()
        detailsHairline.translatesAutoresizingMaskIntoConstraints = false
        detailsHairline.backgroundColor = BearyOnboardingPalette.line2
        detailsContainer.addSubview(detailsHairline)
        NSLayoutConstraint.activate([
            detailsHairline.topAnchor.constraint(equalTo: detailsContainer.topAnchor),
            detailsHairline.leadingAnchor.constraint(equalTo: detailsContainer.leadingAnchor),
            detailsHairline.trailingAnchor.constraint(equalTo: detailsContainer.trailingAnchor),
            detailsHairline.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        let detailsRow = UIStackView()
        detailsRow.translatesAutoresizingMaskIntoConstraints = false
        detailsRow.axis = .horizontal
        detailsRow.distribution = .fillEqually
        detailsRow.spacing = 8
        detailsContainer.addSubview(detailsRow)
        NSLayoutConstraint.activate([
            detailsRow.topAnchor.constraint(equalTo: detailsContainer.topAnchor, constant: 9),
            detailsRow.leadingAnchor.constraint(equalTo: detailsContainer.leadingAnchor),
            detailsRow.trailingAnchor.constraint(equalTo: detailsContainer.trailingAnchor),
            detailsRow.bottomAnchor.constraint(equalTo: detailsContainer.bottomAnchor),
        ])
        if let birthdayText = data.birthdayText {
            detailsRow.addArrangedSubview(makeDetailCell(label: "生日", value: birthdayText))
        }
        if let cityText = data.cityText {
            detailsRow.addArrangedSubview(makeDetailCell(label: "城市", value: cityText))
        }
        detailsRow.addArrangedSubview(makeDetailCell(label: "SINCE", value: stats.sinceText))
        // 统计行（钉底）。
        let statsContainer = UIView()
        statsContainer.translatesAutoresizingMaskIntoConstraints = false
        backView.addSubview(statsContainer)
        NSLayoutConstraint.activate([
            statsContainer.leadingAnchor.constraint(equalTo: backView.leadingAnchor, constant: 16),
            statsContainer.trailingAnchor.constraint(equalTo: backView.trailingAnchor, constant: -16),
            statsContainer.bottomAnchor.constraint(equalTo: backView.bottomAnchor, constant: compact ? -8 : -10),
        ])
        let statsHairline = UIView()
        statsHairline.translatesAutoresizingMaskIntoConstraints = false
        statsHairline.backgroundColor = BearyOnboardingPalette.line2
        statsContainer.addSubview(statsHairline)
        NSLayoutConstraint.activate([
            statsHairline.topAnchor.constraint(equalTo: statsContainer.topAnchor),
            statsHairline.leadingAnchor.constraint(equalTo: statsContainer.leadingAnchor),
            statsHairline.trailingAnchor.constraint(equalTo: statsContainer.trailingAnchor),
            statsHairline.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        let statsRow = UIStackView()
        statsRow.translatesAutoresizingMaskIntoConstraints = false
        statsRow.axis = .horizontal
        statsRow.distribution = .fillEqually
        statsRow.spacing = 8
        statsContainer.addSubview(statsRow)
        NSLayoutConstraint.activate([
            statsRow.topAnchor.constraint(equalTo: statsContainer.topAnchor, constant: 8),
            statsRow.leadingAnchor.constraint(equalTo: statsContainer.leadingAnchor),
            statsRow.trailingAnchor.constraint(equalTo: statsContainer.trailingAnchor),
            statsRow.bottomAnchor.constraint(equalTo: statsContainer.bottomAnchor),
        ])
        statsRow.addArrangedSubview(makeStatCell(number: stats.joinDays, unit: "天", label: "加入天数"))
        statsRow.addArrangedSubview(makeStatCell(number: stats.diaryCount, unit: "篇", label: "写的日记"))
        statsRow.addArrangedSubview(makeStatCell(number: stats.streakDays, unit: "天", label: "连续记录"))
    }

    private func makeDetailCell(label: String, value: String) -> UIView {
        let cell = UIStackView()
        cell.axis = .vertical
        cell.spacing = 2
        let labelView = UILabel()
        labelView.font = UIFont.systemFont(ofSize: 10)
        labelView.textColor = BearyOnboardingPalette.muted
        labelView.text = label
        cell.addArrangedSubview(labelView)
        let valueView = UILabel()
        valueView.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        valueView.textColor = BearyOnboardingPalette.ink
        valueView.text = value
        // 长城市名（如克孜勒苏柯尔克孜自治州）缩字不截尾。
        valueView.adjustsFontSizeToFitWidth = true
        valueView.minimumScaleFactor = 0.7
        cell.addArrangedSubview(valueView)
        return cell
    }

    private func makeStatCell(number: Int, unit: String, label: String) -> UIView {
        let cell = UIStackView()
        cell.axis = .vertical
        cell.spacing = 2
        let numberRow = UIStackView()
        numberRow.axis = .horizontal
        numberRow.alignment = .lastBaseline
        numberRow.spacing = 1
        let numberLabel = UILabel()
        numberLabel.font = UIFont.systemFont(ofSize: compact ? 15 : 17, weight: .bold)
        numberLabel.textColor = BearyOnboardingPalette.ink
        numberLabel.text = "\(number)"
        numberLabel.adjustsFontSizeToFitWidth = true
        numberLabel.minimumScaleFactor = 0.7
        numberRow.addArrangedSubview(numberLabel)
        let unitLabel = UILabel()
        unitLabel.font = UIFont.systemFont(ofSize: 10.5)
        unitLabel.textColor = BearyOnboardingPalette.muted
        unitLabel.text = unit
        numberRow.addArrangedSubview(unitLabel)
        cell.addArrangedSubview(numberRow)
        let labelView = UILabel()
        labelView.font = UIFont.systemFont(ofSize: 10)
        labelView.textColor = BearyOnboardingPalette.muted
        labelView.text = label
        cell.addArrangedSubview(labelView)
        return cell
    }

    /// 皇冠 PLUS 徽章（官方 BearyCrownView＋PLUS 字；只在 Plus 或预览开关开时显示）。
    private func makePlusBadge() -> UIView {
        let badge = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.backgroundColor = UIColor(red: 255.0 / 255.0, green: 243.0 / 255.0, blue: 218.0 / 255.0, alpha: 1)
        badge.layer.cornerRadius = 7
        let row = UIStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 3
        badge.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: badge.topAnchor, constant: 3),
            row.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -6),
            row.bottomAnchor.constraint(equalTo: badge.bottomAnchor, constant: -3),
        ])
        let crownView = BearyCrownView(frame: .zero)
        crownView.translatesAutoresizingMaskIntoConstraints = false
        crownView.widthAnchor.constraint(equalToConstant: 14).isActive = true
        crownView.heightAnchor.constraint(equalToConstant: 14).isActive = true
        row.addArrangedSubview(crownView)
        if !crownView.hasCrown {
            crownView.isHidden = true
        } else {
            crownView.start()
        }
        let plusLabel = UILabel()
        plusLabel.font = UIFont.systemFont(ofSize: 9.5, weight: .bold)
        plusLabel.textColor = UIColor(red: 168.0 / 255.0, green: 106.0 / 255.0, blue: 0.0 / 255.0, alpha: 1)
        plusLabel.text = "PLUS"
        row.addArrangedSubview(plusLabel)
        return badge
    }

    private func loadAvatar(url: URL) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let strongSelf = self else { return }
            guard let dataValue = data, let image = UIImage(data: dataValue) else { return }
            DispatchQueue.main.async {
                strongSelf.avatarPhotoView?.image = image
                strongSelf.avatarPhotoView?.isHidden = false
                strongSelf.avatarGlyphView?.isHidden = true
            }
        }.resume()
    }
}
