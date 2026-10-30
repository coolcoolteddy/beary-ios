import UIKit
import CoreLocation

// ===== 地图胶囊弹卡（2026-10-30；预览第 5/6 屏）=====
// 隐私铁律：本页对非作者绝不渲染标题/正文/图片/心情——它只读 entry 的胶囊三字段
// （capsuleBuried / capsuleUnlockDate / capsuleDistrict）与可见性，不读 title/content/images/mood。
// 作者视角才显示埋点区级 + 解锁日期；他人视角只见占位 + 解锁日期，区级名绝不写进他人文案
// （地图标记点本身已落在区级附近，文案再写区级名等于二次确认——他人行只给条件 yes/no）。
// 解锁判定只在本机做：当前定位逆地理编码出区级后与埋的区级比对，精确坐标不上传、不比对、不进请求。
// 作者不需要过解锁门：作者看自己的胶囊不触发定位权限、不做区级判定；“提前挖出”只是打开自己的详情页，
// 不改胶囊状态、不为他人解锁。取消埋藏走 onCancelCapsule，由地图页调接口；接口失败时标记不消失（fail-closed）。

final class BearyTimeCapsuleSheetViewController: UIViewController, CLLocationManagerDelegate {
    private let entry: Entry
    private let viewerIsAuthor: Bool
    private var onOpenEntry: ((Entry) -> Void)?
    private var onCancelCapsule: ((Entry) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let closeButton = UIButton(type: .system)
    private let capsuleIconView = UIImageView()
    private let titleLabel = UILabel()
    private let statusIconView = UIImageView()
    private let statusLabel = UILabel()
    private let dateIconView = UIImageView()
    private let dateLabel = UILabel()
    private let districtIconView = UIImageView()
    private let districtLabel = UILabel()
    private let districtRow = UIStackView()
    private let conditionLabel = UILabel()
    private let placeholderIconView = UIImageView()
    private let placeholderLabel = UILabel()
    private let placeholderRow = UIStackView()
    private let authorNoteLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let digButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)

    private let locationManager = CLLocationManager()
    private var locationCheckDone = false

    init(entry: Entry, viewerIsAuthor: Bool, onOpenEntry: ((Entry) -> Void)?, onCancelCapsule: ((Entry) -> Void)?) {
        self.entry = entry
        self.viewerIsAuthor = viewerIsAuthor
        self.onOpenEntry = onOpenEntry
        self.onCancelCapsule = onCancelCapsule
        super.init(nibName: nil, bundle: nil)
        title = "时间胶囊"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        build()
        renderStatic()
        if viewerIsAuthor {
            renderAuthor()
        } else {
            renderLockedPending()
            startDistrictCheck()
        }
    }

    private func makeRow(iconView: UIImageView, label: UILabel) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(iconView)
        row.addArrangedSubview(label)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
        ])
        return row
    }

    private func build() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
        ])

        // 顶栏：返回（官方 icon_back）+ 胶囊图标/标题。胶囊图标未注册时图标位隐藏、标题旁不画替代图。
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.accessibilityLabel = "返回"
        closeButton.addTarget(self, action: #selector(didTapClose), for: .touchUpInside)
        capsuleIconView.translatesAutoresizingMaskIntoConstraints = false
        capsuleIconView.contentMode = .scaleAspectFit
        capsuleIconView.tintColor = BearyColors.orange
        if let image = BearyTimeCapsuleIcon.timeCapsuleImage(pointSize: 24) {
            capsuleIconView.image = image
        } else {
            capsuleIconView.isHidden = true
        }
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.boldSystemFont(ofSize: 20)
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = "时间胶囊"
        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.spacing = 8
        headerRow.alignment = .center
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addArrangedSubview(closeButton)
        headerRow.addArrangedSubview(capsuleIconView)
        headerRow.addArrangedSubview(titleLabel)
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            capsuleIconView.widthAnchor.constraint(equalToConstant: 24),
            capsuleIconView.heightAnchor.constraint(equalToConstant: 24),
        ])
        stack.addArrangedSubview(headerRow)

        statusIconView.tintColor = BearyColors.gray
        statusLabel.font = UIFont.systemFont(ofSize: 15)
        statusLabel.textColor = BearyColors.ink
        statusLabel.numberOfLines = 0
        stack.addArrangedSubview(makeRow(iconView: statusIconView, label: statusLabel))

        dateIconView.image = BearyIconImages.image(named: "icon_calendar", pointSize: 20)
        dateIconView.tintColor = BearyColors.gray
        dateLabel.font = UIFont.systemFont(ofSize: 15)
        dateLabel.textColor = BearyColors.ink
        dateLabel.numberOfLines = 0
        stack.addArrangedSubview(makeRow(iconView: dateIconView, label: dateLabel))

        // 埋点区级行：仅作者可见。区级解锁态图标用新图标 icon_district_range；未注册时图标位隐藏、
        // 文案后追加占位标注，不自绘、不拿定位图标顶替（定位图标是另一含义）。
        districtIconView.tintColor = BearyColors.gray
        if let image = BearyTimeCapsuleIcon.districtRangeImage(pointSize: 20) {
            districtIconView.image = image
        } else {
            districtIconView.isHidden = true
        }
        districtLabel.font = UIFont.systemFont(ofSize: 15)
        districtLabel.textColor = BearyColors.ink
        districtLabel.numberOfLines = 0
        districtRow.axis = .horizontal
        districtRow.spacing = 8
        districtRow.alignment = .center
        districtRow.translatesAutoresizingMaskIntoConstraints = false
        districtRow.addArrangedSubview(districtIconView)
        districtRow.addArrangedSubview(districtLabel)
        NSLayoutConstraint.activate([
            districtIconView.widthAnchor.constraint(equalToConstant: 20),
            districtIconView.heightAnchor.constraint(equalToConstant: 20),
        ])
        stack.addArrangedSubview(districtRow)

        conditionLabel.font = UIFont.systemFont(ofSize: 13)
        conditionLabel.textColor = BearyColors.gray
        conditionLabel.numberOfLines = 0
        stack.addArrangedSubview(conditionLabel)

        placeholderIconView.image = BearyIconImages.image(named: "icon_eye_off", pointSize: 20)
        placeholderIconView.tintColor = BearyColors.gray
        placeholderLabel.font = UIFont.systemFont(ofSize: 15)
        placeholderLabel.textColor = BearyColors.ink
        placeholderLabel.numberOfLines = 0
        placeholderRow.axis = .horizontal
        placeholderRow.spacing = 8
        placeholderRow.alignment = .center
        placeholderRow.translatesAutoresizingMaskIntoConstraints = false
        placeholderRow.addArrangedSubview(placeholderIconView)
        placeholderRow.addArrangedSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderIconView.widthAnchor.constraint(equalToConstant: 20),
            placeholderIconView.heightAnchor.constraint(equalToConstant: 20),
        ])
        stack.addArrangedSubview(placeholderRow)

        authorNoteLabel.font = UIFont.systemFont(ofSize: 13)
        authorNoteLabel.textColor = BearyColors.gray
        authorNoteLabel.numberOfLines = 0
        stack.addArrangedSubview(authorNoteLabel)

        // 操作：他人解锁且公开 → 打开日记（右箭头）；作者 → 提前挖出（右箭头）+ 取消埋藏（删除红字）；
        // 其余态只有返回（关闭走顶栏返回钮，不另设底部返回按钮，避免双关闭入口）。
        openButton.setTitle("打开日记", for: .normal)
        openButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        openButton.setImage(BearyIconImages.image(named: "icon_arrow_right", pointSize: 20), for: .normal)
        openButton.tintColor = BearyColors.ink
        openButton.contentHorizontalAlignment = .left
        openButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        openButton.addTarget(self, action: #selector(didTapOpen), for: .touchUpInside)
        stack.addArrangedSubview(openButton)

        digButton.setTitle("查看日记（提前挖出）", for: .normal)
        digButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        digButton.setImage(BearyIconImages.image(named: "icon_arrow_right", pointSize: 20), for: .normal)
        digButton.tintColor = BearyColors.ink
        digButton.contentHorizontalAlignment = .left
        digButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        digButton.translatesAutoresizingMaskIntoConstraints = false
        digButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        digButton.addTarget(self, action: #selector(didTapOpen), for: .touchUpInside)
        stack.addArrangedSubview(digButton)

        cancelButton.setTitle("取消埋藏", for: .normal)
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 16)
        cancelButton.setImage(BearyIconImages.image(named: "icon_trash", pointSize: 20), for: .normal)
        cancelButton.tintColor = BearyColors.red
        cancelButton.contentHorizontalAlignment = .left
        cancelButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        cancelButton.addTarget(self, action: #selector(didTapCancel), for: .touchUpInside)
        stack.addArrangedSubview(cancelButton)
    }

    private func renderStatic() {
        if let dateText = BearyTimeCapsule.unlockDateText(entry: entry) {
            dateLabel.text = "解锁日期：\(dateText)"
        } else {
            dateLabel.text = "解锁日期：未知"
        }
    }

    private func renderAuthor() {
        statusIconView.image = BearyIconImages.image(named: "icon_lock", pointSize: 20)
        statusLabel.text = "你的胶囊"
        if let district = entry.capsuleDistrict?.trimmingCharacters(in: .whitespacesAndNewlines), !district.isEmpty {
            if districtIconView.isHidden {
                districtLabel.text = "埋在：\(district)（区级图标待官方补）"
            } else {
                districtLabel.text = "埋在：\(district)"
            }
        } else {
            districtLabel.text = "埋点区级：未知"
        }
        districtRow.isHidden = false
        conditionLabel.isHidden = true
        placeholderRow.isHidden = true
        authorNoteLabel.isHidden = false
        authorNoteLabel.text = "提前挖出只是你自己看这篇日记，不改胶囊状态、不为他人解锁。取消埋藏后日记恢复普通日记，地图上的胶囊标记消失。"
        openButton.isHidden = true
        digButton.isHidden = false
        cancelButton.isHidden = false
    }

    private func renderLockedPending() {
        statusIconView.image = BearyIconImages.image(named: "icon_hourglass", pointSize: 20)
        statusLabel.text = "时间胶囊 · 未解锁"
        districtRow.isHidden = true
        conditionLabel.isHidden = false
        conditionLabel.text = "正在确认你当前所在区级…"
        placeholderRow.isHidden = false
        placeholderIconView.image = BearyIconImages.image(named: "icon_eye_off", pointSize: 20)
        placeholderLabel.text = "\(BearyTimeCapsule.placeholderTitle)\n标题与内容暂不显示"
        authorNoteLabel.isHidden = true
        openButton.isHidden = true
        digButton.isHidden = true
        cancelButton.isHidden = true
    }

    private func renderEvaluation(_ evaluation: BearyTimeCapsule.UnlockEvaluation) {
        switch evaluation {
        case .malformed:
            statusIconView.image = BearyIconImages.image(named: "icon_lock", pointSize: 20)
            statusLabel.text = "时间胶囊 · 未解锁"
            conditionLabel.text = "胶囊信息不完整，暂无法解锁"
            placeholderRow.isHidden = false
            openButton.isHidden = true
        case .unlocked:
            // 解锁≠公开：先按原可见性分流。私密篇即使双条件满足，他人仍只见占位（fail-closed；
            // 经地图进来的他人本不该看到私密胶囊，此分支是已打开弹卡后的兜底）。
            if BearyTimeCapsule.audienceAfterUnlock(entry: entry) == .everyone {
                statusIconView.image = BearyIconImages.image(named: "icon_calendar", pointSize: 20)
                statusLabel.text = "已解锁"
                conditionLabel.text = "解锁日期已到，且你在同一区级"
                placeholderRow.isHidden = true
                openButton.isHidden = false
            } else {
                statusIconView.image = BearyIconImages.image(named: "icon_lock", pointSize: 20)
                statusLabel.text = "时间胶囊 · 未解锁"
                conditionLabel.text = "该日记为私密，仅作者可见"
                placeholderRow.isHidden = false
                openButton.isHidden = true
            }
        case .dateNotReached:
            statusIconView.image = BearyIconImages.image(named: "icon_hourglass", pointSize: 20)
            statusLabel.text = "时间胶囊 · 未解锁"
            conditionLabel.text = "解锁日期还没到"
            placeholderRow.isHidden = false
            openButton.isHidden = true
        case .notInDistrict:
            statusIconView.image = BearyIconImages.image(named: "icon_lock", pointSize: 20)
            statusLabel.text = "时间胶囊 · 未解锁"
            conditionLabel.text = "解锁日期已到，但你当前不在同一区级"
            placeholderRow.isHidden = false
            openButton.isHidden = true
        case .neitherCondition:
            statusIconView.image = BearyIconImages.image(named: "icon_lock", pointSize: 20)
            statusLabel.text = "时间胶囊 · 未解锁"
            conditionLabel.text = "解锁日期还没到，且你当前不在同一区级"
            placeholderRow.isHidden = false
            openButton.isHidden = true
        case .districtUnknown:
            statusIconView.image = BearyIconImages.image(named: "icon_lock", pointSize: 20)
            statusLabel.text = "时间胶囊 · 未解锁"
            conditionLabel.text = "无法确认你当前所在区级（未授权定位或定位失败），请开启定位权限后重试"
            placeholderRow.isHidden = false
            openButton.isHidden = true
        }
        digButton.isHidden = true
        cancelButton.isHidden = true
    }

    // MARK: - 当前区级判定（本机逆地理编码，精确坐标不上传）

    private func startDistrictCheck() {
        guard !locationCheckDone else { return }
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        let status = CLLocationManager.authorizationStatus()
        if status == .denied || status == .restricted {
            finishDistrictCheck(district: nil)
            return
        }
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            return
        }
        locationManager.requestLocation()
    }

    private func finishDistrictCheck(district: String?) {
        guard !locationCheckDone else { return }
        locationCheckDone = true
        let evaluation = BearyTimeCapsule.evaluate(entry: entry, currentDistrict: district)
        renderEvaluation(evaluation)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard !viewerIsAuthor, !locationCheckDone else { return }
        let status = CLLocationManager.authorizationStatus()
        if status == .denied || status == .restricted {
            finishDistrictCheck(district: nil)
        } else if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finishDistrictCheck(district: nil)
            return
        }
        // 逆地理编码只取区级文本：placemark 其余字段（街道/POI/坐标）一律丢弃，不存、不传、不比对。
        CLGeocoder().reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let district = placemarks?.first.map { BearyLocationDisplay.district(from: $0) } ?? nil
                self.finishDistrictCheck(district: district)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishDistrictCheck(district: nil)
    }

    // MARK: - 操作

    @objc private func didTapClose() {
        dismiss(animated: true)
    }

    @objc private func didTapOpen() {
        let entry = self.entry
        dismiss(animated: true) { [weak self] in
            self?.onOpenEntry?(entry)
        }
    }

    @objc private func didTapCancel() {
        let alert = UIAlertController(
            title: "取消埋藏？",
            message: "取消后这篇日记恢复普通日记，地图上的胶囊标记消失，且不可恢复。",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "再想想", style: .cancel))
        alert.addAction(UIAlertAction(title: "确认取消", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            let entry = self.entry
            self.dismiss(animated: true) { [weak self] in
                self?.onCancelCapsule?(entry)
            }
        })
        present(alert, animated: true)
    }
}
