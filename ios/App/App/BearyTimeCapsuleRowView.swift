import UIKit

// ===== 写日记页“埋进地图”行（2026-10-30；预览第 4 屏）=====
// 位置：编辑器 contentStack 里，定位行正下方（调用方在 buildLocationRow 之后立即建，栈顺序即视觉顺序）。
// 形态：开关行 + 解锁日期行（开关开才出现，关则收起，不留空行）；无位置时调用方整组隐藏（见 Composer）。
// 图标：开关旁用新图标 icon_time_capsule（BearyTimeCapsuleIcon）；日期行用官方已有 icon_calendar；
// icon_time_capsule 资产未注册时 iconView 隐藏、副行追加“（胶囊图标待官方补）”，不自绘、不拿 SF Symbol 顶替。
// 本视图不碰位置与发布逻辑：开关/日期变化只经 delegate 回调给 Composer，校验与发请求全在 Composer。

protocol BearyTimeCapsuleRowViewDelegate: AnyObject {
func timeCapsuleRowDidToggle(on: Bool)
func timeCapsuleRowDidChangeDate(_ date: Date)
}

final class BearyTimeCapsuleRowView: UIView {
weak var delegate: BearyTimeCapsuleRowViewDelegate?

private let mainStack = UIStackView()
private let switchRow = UIStackView()
private let iconView = UIImageView()
private let titleLabel = UILabel()
private let subtitleLabel = UILabel()
private let textStack = UIStackView()
private let capsuleSwitch = UISwitch()
private let dateRow = UIStackView()
private let calendarIconView = UIImageView()
private let dateLabel = UILabel()
private let datePicker = UIDatePicker()
private let noteLabel = UILabel()

/// 开关当前值（调用方校验失败时可调回 false，视图与状态同步，不由视图自作主张）。
var isOn: Bool {
get { capsuleSwitch.isOn}
set { capsuleSwitch.isOn = newValue; refreshDateRowVisibility()}
}

var selectedDate: Date {
return datePicker.date
}

override init(frame: CGRect) {
super.init(frame: frame)
build()
}

required init?(coder: NSCoder) {
fatalError("init(coder:) has not been implemented")
}

private func build() {
iconView.translatesAutoresizingMaskIntoConstraints = false
iconView.contentMode =.scaleAspectFit
iconView.tintColor = BearyColors.orange
if let image = BearyTimeCapsuleIcon.timeCapsuleImage(pointSize: 16) {
iconView.image = image
} else {
// 占位：资产未到时不画替代图，图标位直接隐藏，副行文字标注待补（见 refreshPlaceholderNote）。
iconView.isHidden = true
}
titleLabel.translatesAutoresizingMaskIntoConstraints = false
titleLabel.font = UIFont.systemFont(ofSize: 13)
titleLabel.textColor = BearyColors.ink
titleLabel.text = "埋进地图"
subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
subtitleLabel.font = UIFont.systemFont(ofSize: 12)
subtitleLabel.textColor = BearyColors.gray
subtitleLabel.numberOfLines = 0
subtitleLabel.text = "写成时间胶囊，埋在当前区级"
refreshPlaceholderNote()
textStack.axis =.vertical
textStack.spacing = 2
textStack.translatesAutoresizingMaskIntoConstraints = false
textStack.addArrangedSubview(titleLabel)
textStack.addArrangedSubview(subtitleLabel)
capsuleSwitch.translatesAutoresizingMaskIntoConstraints = false
capsuleSwitch.addTarget(self, action: #selector(didToggleSwitch), for:.valueChanged)
capsuleSwitch.accessibilityLabel = "埋进地图"
switchRow.axis =.horizontal
switchRow.spacing = 6
switchRow.alignment =.center
switchRow.translatesAutoresizingMaskIntoConstraints = false
switchRow.addArrangedSubview(iconView)
switchRow.addArrangedSubview(textStack)
switchRow.addArrangedSubview(capsuleSwitch)

calendarIconView.translatesAutoresizingMaskIntoConstraints = false
calendarIconView.image = BearyIconImages.image(named: "icon_calendar", pointSize: 16)
calendarIconView.tintColor = BearyColors.gray
calendarIconView.contentMode =.scaleAspectFit
dateLabel.translatesAutoresizingMaskIntoConstraints = false
dateLabel.font = UIFont.systemFont(ofSize: 13)
dateLabel.textColor = BearyColors.gray
dateLabel.text = "解锁日期"
datePicker.translatesAutoresizingMaskIntoConstraints = false
datePicker.datePickerMode =.date
datePicker.preferredDatePickerStyle =.compact
// 解锁日期只允许今天及以后：过去日期在视图层就选不到，Composer 发布时仍会再校验一次（防旁路）。
datePicker.minimumDate = Calendar.current.startOfDay(for: Date())
if let defaultDate = Calendar.current.date(byAdding:.day, value: 30, to: Date()) {
datePicker.date = defaultDate
}
datePicker.addTarget(self, action: #selector(didChangeDate), for:.valueChanged)
dateRow.axis =.horizontal
dateRow.spacing = 6
dateRow.alignment =.center
dateRow.translatesAutoresizingMaskIntoConstraints = false
dateRow.addArrangedSubview(calendarIconView)
dateRow.addArrangedSubview(dateLabel)
dateRow.addArrangedSubview(datePicker)

noteLabel.translatesAutoresizingMaskIntoConstraints = false
noteLabel.font = UIFont.systemFont(ofSize: 12)
noteLabel.textColor = BearyColors.orange
noteLabel.numberOfLines = 0
noteLabel.text = "解锁还要满足：到解锁日期且人在同一区级"

mainStack.axis =.vertical
mainStack.spacing = 6
mainStack.translatesAutoresizingMaskIntoConstraints = false
mainStack.addArrangedSubview(switchRow)
mainStack.addArrangedSubview(dateRow)
mainStack.addArrangedSubview(noteLabel)
addSubview(mainStack)
NSLayoutConstraint.activate([
mainStack.topAnchor.constraint(equalTo: topAnchor),
mainStack.leadingAnchor.constraint(equalTo: leadingAnchor),
mainStack.trailingAnchor.constraint(equalTo: trailingAnchor),
mainStack.bottomAnchor.constraint(equalTo: bottomAnchor),
iconView.widthAnchor.constraint(equalToConstant: 16),
iconView.heightAnchor.constraint(equalToConstant: 16),
calendarIconView.widthAnchor.constraint(equalToConstant: 16),
calendarIconView.heightAnchor.constraint(equalToConstant: 16),
])
refreshDateRowVisibility()
}

private func refreshPlaceholderNote() {
if iconView.isHidden {
subtitleLabel.text = "写成时间胶囊，埋在当前区级（胶囊图标待官方补）"
} else {
subtitleLabel.text = "写成时间胶囊，埋在当前区级"
}
}

private func refreshDateRowVisibility() {
// 关则收起：日期行与说明行一起隐藏，不留空行；开则两者都出现。
let show = capsuleSwitch.isOn
dateRow.isHidden =!show
noteLabel.isHidden =!show
}

func setDate(_ date: Date, animated: Bool = false) {
_ = animated
datePicker.date = date
}

@objc private func didToggleSwitch() {
refreshDateRowVisibility()
delegate?.timeCapsuleRowDidToggle(on: capsuleSwitch.isOn)
}

@objc private func didChangeDate() {
delegate?.timeCapsuleRowDidChangeDate(datePicker.date)
}
}
