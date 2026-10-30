import UIKit

// MARK: - 词汇指纹（年度回顾首屏主视觉 + 写作统计卡紧凑版）
//
// 口径（预览 preview-past-self-and-wordprint.html 功能 4 + 本批任务书）：
// - 每年一张：只算指定年份当年的正文；看当年不触发旧年重算，切到旧年时只算旧年那一张。
// - 排序：按出现篇数降序（不是总次数）；字号与条长都按出现篇数定，不做随机散布、
//   旋转、大小杂乱的词云；平手时总次数降序、再按首次出现顺序（稳定，不随字典序抖动）。
// - 点词只显示出现篇数 / 总次数 / 月份分布，不展开正文：详情页收到的是
//   WordprintItem（词 + 计数 + 月份篇数），不带任何 Entry、正文、标题与 id，
//   类型上就不可能从详情跳回原文。
// - 他人口径 fail-closed：统计函数内部先按 visibleEntries(isOwn:) 再过滤一次
//   （调用方传来的已是可见条目，双层过滤；他人态 isPublic != true、占位、无 id
//   条目一律排除），月份分布同样只从过滤后的条目算——私密篇独有的词进不了
//   他人词表，私密篇集中的月份也不会在他人月份分布里冒头。
// - 不新增写库：纯内存函数，语料就是个人主页已拉到的作者 scope 全量分页
//   （modulesCorpus），不拉新接口、不写 UserDefaults / 文件 / 数据库；
//   切年份只对内存数组重算当选年份，不重拉、不重算其他年份。
// - 分词口径沿用批 D 常出现的词：系统 NLTokenizer（zh-Hans，词单位）+ 停用词 /
//   标点 / 单字 / 纯数字 / emoji 过滤（见 BearyProfilePersonalLogic.isCountableWord），
//   本文件不自写分词、不另建停用词表。
// - 图标：只走官方包。icon_fingerprint 在基线 e13b455 的 xcassets 里并不存在
//   （已核实：248 个 imageset 中无此名；预览页的 fingerprint 是网页 beary-ui
//   路径，不是 iOS 资产）——此处只引用该名，取不到图时图标位隐藏、只留文字标题，
//   不用 SF Symbol 顶替、不自绘；Li 补官方包进 xcassets 后自动出现。
//   仅公开篇徽标引用 imageset 名 "icon_public_only"（#229 已注册），未注册时同样只留文字标注
//   「仅公开篇」，不自绘、不拼 globe + lock 组合顶替单枚徽标。

/// 统计口径：本人 = 全部篇（含私密）；他人 = 仅公开篇。
enum BearyWordprintScope {
    case own
    case other

    var labelText: String {
        switch self {
        case .own:
            return "全部篇（含私密）"
        case .other:
            return "仅公开篇"
        }
    }
}

enum BearyWordprintMode {
    /// 年报首屏主视觉：全部词（默认前 15），词行可点进详情。
    case hero
    /// 写作统计卡内紧凑版：只显前 4 个词，词行不点——整卡点按进年度回顾，
    /// 避免词行手势与整卡手势双触发；点词看篇数只在首屏主视觉里。
    case compact
}

/// 仅公开篇徽标行：icon_public_only 资产（#229 已注册）+ 文字标注；资产未到时只留文字。
/// 他人口径的蓝色取 BearyColors.blue（提示性元素次色）；本人态为灰色说明文字。
func bearyMakeWordprintScopeBadge(scope: BearyWordprintScope) -> UIView {
    let row = UIStackView()
    row.translatesAutoresizingMaskIntoConstraints = false
    row.axis = .horizontal
    row.spacing = 4
    row.alignment = .center
    if scope == .other, let badgeImage = UIImage(named: "icon_public_only") {
        let badgeView = UIImageView(image: badgeImage)
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            badgeView.widthAnchor.constraint(equalToConstant: 14),
            badgeView.heightAnchor.constraint(equalToConstant: 14),
        ])
        row.addArrangedSubview(badgeView)
    }
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = UIFont.systemFont(ofSize: 12)
    label.textColor = scope == .other ? BearyColors.blue : BearyColors.gray
    label.text = scope.labelText
    row.addArrangedSubview(label)
    return row
}

/// 词汇指纹视图：标题行（指纹图标 + 「词汇指纹」+ 年份）+ 口径徽标行 + 词行。
/// 词行 = 词（字号按出现篇数缩放）+ 篇数 / 总次数 + 按出现篇数定长的橙条。
final class BearyWordprintView: UIView {

    private let mode: BearyWordprintMode
    private var shownItems: [BearyProfilePersonalLogic.WordprintItem] = []
    var onSelect: ((BearyProfilePersonalLogic.WordprintItem) -> Void)?

    private let fingerprintImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        // 基线无 icon_fingerprint 资产时 image 为 nil，见文件头注记：图标位隐藏。
        imageView.image = BearyIconImages.image(named: "icon_fingerprint", pointSize: 20)
        imageView.tintColor = BearyColors.ink
        imageView.isHidden = imageView.image == nil
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        label.textColor = BearyColors.ink
        label.text = "词汇指纹"
        return label
    }()

    private let yearLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = BearyColors.gray
        return label
    }()

    private let scopeContainer: UIView = {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        return container
    }()

    private let rowsStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 12
        return stack
    }()

    init(mode: BearyWordprintMode) {
        self.mode = mode
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let headerRow = UIStackView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.axis = .horizontal
        headerRow.spacing = 6
        headerRow.alignment = .center
        headerRow.addArrangedSubview(fingerprintImageView)
        headerRow.addArrangedSubview(titleLabel)
        let headerSpacer = UIView()
        headerSpacer.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addArrangedSubview(headerSpacer)
        headerRow.addArrangedSubview(yearLabel)
        if mode == .compact {
            rowsStack.spacing = 8
            titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        }
        NSLayoutConstraint.activate([
            fingerprintImageView.widthAnchor.constraint(equalToConstant: 20),
            fingerprintImageView.heightAnchor.constraint(equalToConstant: 20),
        ])
        let outer = UIStackView(arrangedSubviews: [headerRow, scopeContainer, rowsStack])
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.axis = .vertical
        outer.spacing = 8
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func configure(with wordprint: BearyProfilePersonalLogic.Wordprint, scope: BearyWordprintScope) {
        yearLabel.text = "\(wordprint.year) 年"
        for arrangedView in scopeContainer.subviews {
            arrangedView.removeFromSuperview()
        }
        let badge = bearyMakeWordprintScopeBadge(scope: scope)
        scopeContainer.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: scopeContainer.topAnchor),
            badge.leadingAnchor.constraint(equalTo: scopeContainer.leadingAnchor),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: scopeContainer.trailingAnchor),
            badge.bottomAnchor.constraint(equalTo: scopeContainer.bottomAnchor),
        ])
        for arrangedView in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(arrangedView)
            arrangedView.removeFromSuperview()
        }
        let shown: [BearyProfilePersonalLogic.WordprintItem]
        if mode == .compact {
            shown = Array(wordprint.items.prefix(4))
        } else {
            shown = wordprint.items
        }
        shownItems = shown
        let maxDocCount = shown.map { $0.docCount }.max() ?? 0
        for (index, item) in shown.enumerated() {
            rowsStack.addArrangedSubview(makeRow(item: item, maxDocCount: maxDocCount, index: index))
        }
    }

    private func makeRow(item: BearyProfilePersonalLogic.WordprintItem, maxDocCount: Int, index: Int) -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.tag = index
        let ratio: CGFloat
        if maxDocCount > 0 {
            ratio = CGFloat(item.docCount) / CGFloat(maxDocCount)
        } else {
            ratio = 0
        }
        let wordLabel = UILabel()
        wordLabel.translatesAutoresizingMaskIntoConstraints = false
        wordLabel.numberOfLines = 1
        wordLabel.lineBreakMode = .byTruncatingTail
        wordLabel.textColor = BearyColors.ink
        wordLabel.text = item.word
        if mode == .compact {
            wordLabel.font = UIFont.systemFont(ofSize: 13 + 4 * ratio, weight: .semibold)
        } else {
            wordLabel.font = UIFont.systemFont(ofSize: 15 + 7 * ratio, weight: .semibold)
        }
        let countLabel = UILabel()
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = UIFont.systemFont(ofSize: 12)
        countLabel.textColor = BearyColors.gray
        countLabel.text = "\(item.docCount) 篇 · \(item.totalCount) 次"
        let wordRow = UIStackView(arrangedSubviews: [wordLabel, UIView(), countLabel])
        wordRow.translatesAutoresizingMaskIntoConstraints = false
        wordRow.axis = .horizontal
        wordRow.spacing = 8
        wordRow.alignment = .center
        let barBackground = UIView()
        barBackground.translatesAutoresizingMaskIntoConstraints = false
        barBackground.backgroundColor = BearyColors.faint
        barBackground.layer.cornerRadius = 3
        barBackground.clipsToBounds = true
        let barFill = UIView()
        barFill.translatesAutoresizingMaskIntoConstraints = false
        barFill.backgroundColor = BearyColors.orange
        barBackground.addSubview(barFill)
        let barHeight: CGFloat = mode == .compact ? 6 : 8
        if ratio > 0 {
            NSLayoutConstraint.activate([
                barFill.topAnchor.constraint(equalTo: barBackground.topAnchor),
                barFill.leadingAnchor.constraint(equalTo: barBackground.leadingAnchor),
                barFill.bottomAnchor.constraint(equalTo: barBackground.bottomAnchor),
                barFill.widthAnchor.constraint(equalTo: barBackground.widthAnchor, multiplier: ratio),
            ])
        } else {
            NSLayoutConstraint.activate([
                barFill.topAnchor.constraint(equalTo: barBackground.topAnchor),
                barFill.leadingAnchor.constraint(equalTo: barBackground.leadingAnchor),
                barFill.bottomAnchor.constraint(equalTo: barBackground.bottomAnchor),
                barFill.widthAnchor.constraint(equalToConstant: 0),
            ])
        }
        NSLayoutConstraint.activate([
            barBackground.heightAnchor.constraint(equalToConstant: barHeight),
        ])
        let rowStack = UIStackView(arrangedSubviews: [wordRow, barBackground])
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.axis = .vertical
        rowStack.spacing = 4
        row.addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: row.topAnchor),
            rowStack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            rowStack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        if mode == .hero {
            row.isUserInteractionEnabled = true
            let tap = UITapGestureRecognizer(target: self, action: #selector(rowTapped(_:)))
            row.addGestureRecognizer(tap)
            row.accessibilityTraits = .button
            row.accessibilityLabel = "\(item.word)，出现 \(item.docCount) 篇，总计 \(item.totalCount) 次"
            row.accessibilityHint = "点按查看篇数与月份分布"
        }
        return row
    }

    @objc private func rowTapped(_ sender: UITapGestureRecognizer) {
        guard mode == .hero,
              let row = sender.view,
              row.tag >= 0,
              row.tag < shownItems.count else { return }
        onSelect?(shownItems[row.tag])
    }
}

// MARK: - 点词详情：只显示篇数 / 总次数 / 月份分布，不展示正文
//
// 本页不接收 Entry、不接收正文、不接收 id，调用方即使想跳原文也无据可跳；
// 月份分布按篇数计（同一篇内多次出现当月只计 1 篇），12 个月篇数之和等于出现篇数。

final class BearyWordprintDetailViewController: UIViewController {

    private let item: BearyProfilePersonalLogic.WordprintItem
    private let year: Int
    private let scope: BearyWordprintScope

    init(item: BearyProfilePersonalLogic.WordprintItem, year: Int, scope: BearyWordprintScope) {
        self.item = item
        self.year = year
        self.scope = scope
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        let backButton = UIButton(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        backButton.tintColor = BearyColors.ink
        backButton.accessibilityLabel = "返回"
        backButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()
        view.addSubview(backButton)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            backButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            backButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 56),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -32),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])

        let wordLabel = UILabel()
        wordLabel.font = UIFont.systemFont(ofSize: 24, weight: .heavy)
        wordLabel.textColor = BearyColors.ink
        wordLabel.numberOfLines = 0
        wordLabel.text = item.word
        stack.addArrangedSubview(wordLabel)

        let yearLabel = UILabel()
        yearLabel.font = UIFont.systemFont(ofSize: 13)
        yearLabel.textColor = BearyColors.gray
        yearLabel.text = "\(year) 年"
        stack.addArrangedSubview(yearLabel)

        stack.addArrangedSubview(bearyMakeWordprintScopeBadge(scope: scope))

        let countsLabel = UILabel()
        countsLabel.numberOfLines = 0
        countsLabel.font = UIFont.systemFont(ofSize: 15)
        countsLabel.textColor = BearyColors.ink
        countsLabel.text = "出现 \(item.docCount) 篇 · 总计 \(item.totalCount) 次"
        stack.addArrangedSubview(countsLabel)

        let monthsTitle = UILabel()
        monthsTitle.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        monthsTitle.textColor = BearyColors.ink
        monthsTitle.text = "月份分布（按篇数）"
        stack.addArrangedSubview(monthsTitle)

        let maxMonthCount = item.monthDocCounts.values.max() ?? 0
        for month in 1...12 {
            let monthCount = item.monthDocCounts[month] ?? 0
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .center
            let monthLabel = UILabel()
            monthLabel.font = UIFont.systemFont(ofSize: 13)
            monthLabel.textColor = BearyColors.ink
            monthLabel.text = "\(month) 月"
            monthLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
            let barBackground = UIView()
            barBackground.backgroundColor = BearyColors.faint
            barBackground.layer.cornerRadius = 4
            barBackground.clipsToBounds = true
            let barFill = UIView()
            barFill.translatesAutoresizingMaskIntoConstraints = false
            barFill.backgroundColor = BearyColors.orange
            barBackground.addSubview(barFill)
            if maxMonthCount > 0, monthCount > 0 {
                NSLayoutConstraint.activate([
                    barFill.topAnchor.constraint(equalTo: barBackground.topAnchor),
                    barFill.leadingAnchor.constraint(equalTo: barBackground.leadingAnchor),
                    barFill.bottomAnchor.constraint(equalTo: barBackground.bottomAnchor),
                    barFill.widthAnchor.constraint(equalTo: barBackground.widthAnchor, multiplier: CGFloat(monthCount) / CGFloat(maxMonthCount)),
                ])
            } else {
                NSLayoutConstraint.activate([
                    barFill.topAnchor.constraint(equalTo: barBackground.topAnchor),
                    barFill.leadingAnchor.constraint(equalTo: barBackground.leadingAnchor),
                    barFill.bottomAnchor.constraint(equalTo: barBackground.bottomAnchor),
                    barFill.widthAnchor.constraint(equalToConstant: 0),
                ])
            }
            barBackground.heightAnchor.constraint(equalToConstant: 8).isActive = true
            let countLabel = UILabel()
            countLabel.font = UIFont.systemFont(ofSize: 13)
            countLabel.textColor = BearyColors.gray
            countLabel.text = "\(monthCount) 篇"
            row.addArrangedSubview(monthLabel)
            row.addArrangedSubview(barBackground)
            row.addArrangedSubview(countLabel)
            stack.addArrangedSubview(row)
        }

        let footnote = UILabel()
        footnote.numberOfLines = 0
        footnote.font = UIFont.systemFont(ofSize: 12)
        footnote.textColor = BearyColors.gray
        footnote.text = "只显示篇数与月份分布，不展示正文。"
        stack.addArrangedSubview(footnote)
    }

    @objc private func closeTapped() {
        dismiss(animated: true, completion: nil)
    }
}
