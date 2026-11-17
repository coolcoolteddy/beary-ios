import Foundation

/// 注册后引导 ID 卡城市三级级联数据（国家→地区→市）。
/// 中国 34 省级＋地级市全量内嵌；其余 15 国取主要地区与城市。
/// 定位反查到的三元组经 `match` 归一化后与本表比对（容忍「市/省」等后缀差异）。
enum BearyCityData {

    struct Region {
        let name: String
        let cities: [String]
    }

    struct Country {
        let name: String
        let regions: [Region]
    }

    static let countries: [Country] = [
        Country(name: "中国", regions: [
            Region(name: "北京市", cities: ["北京市"]),
            Region(name: "天津市", cities: ["天津市"]),
            Region(name: "河北省", cities: ["石家庄市", "唐山市", "秦皇岛市", "邯郸市", "邢台市", "保定市", "张家口市", "承德市", "沧州市", "廊坊市", "衡水市"]),
            Region(name: "山西省", cities: ["太原市", "大同市", "阳泉市", "长治市", "晋城市", "朔州市", "晋中市", "运城市", "忻州市", "临汾市", "吕梁市"]),
            Region(name: "内蒙古自治区", cities: ["呼和浩特市", "包头市", "乌海市", "赤峰市", "通辽市", "鄂尔多斯市", "呼伦贝尔市", "巴彦淖尔市", "乌兰察布市", "兴安盟", "锡林郭勒盟", "阿拉善盟"]),
            Region(name: "辽宁省", cities: ["沈阳市", "大连市", "鞍山市", "抚顺市", "本溪市", "丹东市", "锦州市", "营口市", "阜新市", "辽阳市", "盘锦市", "铁岭市", "朝阳市", "葫芦岛市"]),
            Region(name: "吉林省", cities: ["长春市", "吉林市", "四平市", "辽源市", "通化市", "白山市", "松原市", "白城市", "延边朝鲜族自治州"]),
            Region(name: "黑龙江省", cities: ["哈尔滨市", "齐齐哈尔市", "鸡西市", "鹤岗市", "双鸭山市", "大庆市", "伊春市", "佳木斯市", "七台河市", "牡丹江市", "黑河市", "绥化市", "大兴安岭地区"]),
            Region(name: "上海市", cities: ["上海市"]),
            Region(name: "江苏省", cities: ["南京市", "无锡市", "徐州市", "常州市", "苏州市", "南通市", "连云港市", "淮安市", "盐城市", "扬州市", "镇江市", "泰州市", "宿迁市"]),
            Region(name: "浙江省", cities: ["杭州市", "宁波市", "温州市", "嘉兴市", "湖州市", "绍兴市", "金华市", "衢州市", "舟山市", "台州市", "丽水市"]),
            Region(name: "安徽省", cities: ["合肥市", "芜湖市", "蚌埠市", "淮南市", "马鞍山市", "淮北市", "铜陵市", "安庆市", "黄山市", "滁州市", "阜阳市", "宿州市", "六安市", "亳州市", "池州市", "宣城市"]),
            Region(name: "福建省", cities: ["福州市", "厦门市", "莆田市", "三明市", "泉州市", "漳州市", "南平市", "龙岩市", "宁德市"]),
            Region(name: "江西省", cities: ["南昌市", "景德镇市", "萍乡市", "九江市", "新余市", "鹰潭市", "赣州市", "吉安市", "宜春市", "抚州市", "上饶市"]),
            Region(name: "山东省", cities: ["济南市", "青岛市", "淄博市", "枣庄市", "东营市", "烟台市", "潍坊市", "济宁市", "泰安市", "威海市", "日照市", "临沂市", "德州市", "聊城市", "滨州市", "菏泽市"]),
            Region(name: "河南省", cities: ["郑州市", "开封市", "洛阳市", "平顶山市", "安阳市", "鹤壁市", "新乡市", "焦作市", "濮阳市", "许昌市", "漯河市", "三门峡市", "南阳市", "商丘市", "信阳市", "周口市", "驻马店市", "济源市"]),
            Region(name: "湖北省", cities: ["武汉市", "黄石市", "十堰市", "宜昌市", "襄阳市", "鄂州市", "荆门市", "孝感市", "荆州市", "黄冈市", "咸宁市", "随州市", "恩施土家族苗族自治州", "仙桃市", "潜江市", "天门市", "神农架林区"]),
            Region(name: "湖南省", cities: ["长沙市", "株洲市", "湘潭市", "衡阳市", "邵阳市", "岳阳市", "常德市", "张家界市", "益阳市", "郴州市", "永州市", "怀化市", "娄底市", "湘西土家族苗族自治州"]),
            Region(name: "广东省", cities: ["广州市", "韶关市", "深圳市", "珠海市", "汕头市", "佛山市", "江门市", "湛江市", "茂名市", "肇庆市", "惠州市", "梅州市", "汕尾市", "河源市", "阳江市", "清远市", "东莞市", "中山市", "潮州市", "揭阳市", "云浮市"]),
            Region(name: "广西壮族自治区", cities: ["南宁市", "柳州市", "桂林市", "梧州市", "北海市", "防城港市", "钦州市", "贵港市", "玉林市", "百色市", "贺州市", "河池市", "来宾市", "崇左市"]),
            Region(name: "海南省", cities: ["海口市", "三亚市", "三沙市", "儋州市", "五指山市", "琼海市", "文昌市", "万宁市", "东方市", "定安县", "屯昌县", "澄迈县", "临高县", "白沙黎族自治县", "昌江黎族自治县", "乐东黎族自治县", "陵水黎族自治县", "保亭黎族苗族自治县", "琼中黎族苗族自治县"]),
            Region(name: "重庆市", cities: ["重庆市"]),
            Region(name: "四川省", cities: ["成都市", "自贡市", "攀枝花市", "泸州市", "德阳市", "绵阳市", "广元市", "遂宁市", "内江市", "乐山市", "南充市", "眉山市", "宜宾市", "广安市", "达州市", "雅安市", "巴中市", "资阳市", "阿坝藏族羌族自治州", "甘孜藏族自治州", "凉山彝族自治州"]),
            Region(name: "贵州省", cities: ["贵阳市", "六盘水市", "遵义市", "安顺市", "毕节市", "铜仁市", "黔西南布依族苗族自治州", "黔东南苗族侗族自治州", "黔南布依族苗族自治州"]),
            Region(name: "云南省", cities: ["昆明市", "曲靖市", "玉溪市", "保山市", "昭通市", "丽江市", "普洱市", "临沧市", "楚雄彝族自治州", "红河哈尼族彝族自治州", "文山壮族苗族自治州", "西双版纳傣族自治州", "大理白族自治州", "德宏傣族景颇族自治州", "怒江傈僳族自治州", "迪庆藏族自治州"]),
            Region(name: "西藏自治区", cities: ["拉萨市", "日喀则市", "昌都市", "林芝市", "山南市", "那曲市", "阿里地区"]),
            Region(name: "陕西省", cities: ["西安市", "铜川市", "宝鸡市", "咸阳市", "渭南市", "延安市", "汉中市", "榆林市", "安康市", "商洛市"]),
            Region(name: "甘肃省", cities: ["兰州市", "嘉峪关市", "金昌市", "白银市", "天水市", "武威市", "张掖市", "平凉市", "酒泉市", "庆阳市", "定西市", "陇南市", "临夏回族自治州", "甘南藏族自治州"]),
            Region(name: "青海省", cities: ["西宁市", "海东市", "海北藏族自治州", "黄南藏族自治州", "海南藏族自治州", "果洛藏族自治州", "玉树藏族自治州", "海西蒙古族藏族自治州"]),
            Region(name: "宁夏回族自治区", cities: ["银川市", "石嘴山市", "吴忠市", "固原市", "中卫市"]),
            Region(name: "新疆维吾尔自治区", cities: ["乌鲁木齐市", "克拉玛依市", "吐鲁番市", "哈密市", "昌吉回族自治州", "博尔塔拉蒙古自治州", "巴音郭楞蒙古自治州", "阿克苏地区", "克孜勒苏柯尔克孜自治州", "喀什地区", "和田地区", "伊犁哈萨克自治州", "塔城地区", "阿勒泰地区", "石河子市", "阿拉尔市", "图木舒克市", "五家渠市", "北屯市", "铁门关市", "双河市", "可克达拉市", "昆玉市", "胡杨河市", "新星市"]),
            Region(name: "台湾省", cities: ["台北市", "高雄市", "基隆市", "新竹市", "嘉义市", "台中市", "台南市", "新北市", "宜兰县", "桃园市", "新竹县", "苗栗县", "彰化县", "南投县", "云林县", "嘉义县", "屏东县", "台东县", "花莲县", "澎湖县", "金门县", "连江县"]),
            Region(name: "香港特别行政区", cities: ["香港"]),
            Region(name: "澳门特别行政区", cities: ["澳门"]),
        ]),
        Country(name: "美国", regions: [
            Region(name: "加利福尼亚州", cities: ["洛杉矶", "旧金山", "圣地亚哥", "萨克拉门托", "圣何塞", "弗雷斯诺"]),
            Region(name: "纽约州", cities: ["纽约", "布法罗", "罗彻斯特", "锡拉丘兹"]),
            Region(name: "得克萨斯州", cities: ["休斯敦", "达拉斯", "奥斯汀", "圣安东尼奥", "沃斯堡"]),
            Region(name: "佛罗里达州", cities: ["迈阿密", "奥兰多", "坦帕", "杰克逊维尔"]),
            Region(name: "伊利诺伊州", cities: ["芝加哥", "斯普林菲尔德"]),
            Region(name: "华盛顿州", cities: ["西雅图", "斯波坎", "塔科马"]),
            Region(name: "马萨诸塞州", cities: ["波士顿", "剑桥"]),
            Region(name: "华盛顿哥伦比亚特区", cities: ["华盛顿"]),
            Region(name: "内华达州", cities: ["拉斯维加斯", "里诺"]),
            Region(name: "亚利桑那州", cities: ["菲尼克斯", "图森"]),
            Region(name: "科罗拉多州", cities: ["丹佛", "博尔德"]),
            Region(name: "俄勒冈州", cities: ["波特兰", "尤金"]),
            Region(name: "佐治亚州", cities: ["亚特兰大", "萨凡纳"]),
            Region(name: "密歇根州", cities: ["底特律", "安娜堡"]),
            Region(name: "宾夕法尼亚州", cities: ["费城", "匹兹堡"]),
            Region(name: "夏威夷州", cities: ["檀香山"]),
            Region(name: "阿拉斯加州", cities: ["安克雷奇"]),
        ]),
        Country(name: "日本", regions: [
            Region(name: "东京都", cities: ["东京"]),
            Region(name: "大阪府", cities: ["大阪"]),
            Region(name: "神奈川县", cities: ["横滨", "川崎"]),
            Region(name: "爱知县", cities: ["名古屋"]),
            Region(name: "北海道", cities: ["札幌", "函馆"]),
            Region(name: "福冈县", cities: ["福冈", "北九州"]),
            Region(name: "京都府", cities: ["京都"]),
            Region(name: "兵库县", cities: ["神户"]),
            Region(name: "冲绳县", cities: ["那霸"]),
            Region(name: "宫城县", cities: ["仙台"]),
            Region(name: "广岛县", cities: ["广岛"]),
            Region(name: "奈良县", cities: ["奈良"]),
        ]),
        Country(name: "韩国", regions: [
            Region(name: "首尔特别市", cities: ["首尔"]),
            Region(name: "釜山广域市", cities: ["釜山"]),
            Region(name: "仁川广域市", cities: ["仁川"]),
            Region(name: "大邱广域市", cities: ["大邱"]),
            Region(name: "大田广域市", cities: ["大田"]),
            Region(name: "光州广域市", cities: ["光州"]),
            Region(name: "蔚山广域市", cities: ["蔚山"]),
            Region(name: "京畿道", cities: ["水原", "城南", "高阳"]),
            Region(name: "江原道", cities: ["春川", "江陵"]),
            Region(name: "忠清北道", cities: ["清州"]),
            Region(name: "忠清南道", cities: ["天安"]),
            Region(name: "全罗北道", cities: ["全州"]),
            Region(name: "全罗南道", cities: ["木浦", "丽水"]),
            Region(name: "庆尚北道", cities: ["浦项", "庆州"]),
            Region(name: "庆尚南道", cities: ["昌原", "晋州"]),
            Region(name: "济州特别自治道", cities: ["济州"]),
        ]),
        Country(name: "英国", regions: [
            Region(name: "英格兰", cities: ["伦敦", "曼彻斯特", "伯明翰", "利物浦", "利兹", "布里斯托", "谢菲尔德", "纽卡斯尔", "剑桥", "牛津", "约克", "巴斯"]),
            Region(name: "苏格兰", cities: ["爱丁堡", "格拉斯哥", "阿伯丁", "邓迪"]),
            Region(name: "威尔士", cities: ["卡迪夫", "斯旺西"]),
            Region(name: "北爱尔兰", cities: ["贝尔法斯特"]),
        ]),
        Country(name: "法国", regions: [
            Region(name: "法兰西岛大区", cities: ["巴黎", "凡尔赛"]),
            Region(name: "普罗旺斯-阿尔卑斯-蓝色海岸大区", cities: ["马赛", "尼斯", "戛纳"]),
            Region(name: "奥弗涅-罗讷-阿尔卑斯大区", cities: ["里昂", "格勒诺布尔"]),
            Region(name: "新阿基坦大区", cities: ["波尔多", "拉罗谢尔"]),
            Region(name: "奥克西塔尼大区", cities: ["图卢兹", "蒙彼利埃"]),
            Region(name: "上法兰西大区", cities: ["里尔"]),
            Region(name: "大东部大区", cities: ["斯特拉斯堡", "南锡"]),
            Region(name: "布列塔尼大区", cities: ["雷恩", "圣马洛"]),
            Region(name: "卢瓦尔河地区大区", cities: ["南特", "昂热"]),
            Region(name: "诺曼底大区", cities: ["鲁昂", "卡昂"]),
        ]),
        Country(name: "德国", regions: [
            Region(name: "柏林", cities: ["柏林"]),
            Region(name: "巴伐利亚州", cities: ["慕尼黑", "纽伦堡", "奥格斯堡"]),
            Region(name: "北莱茵-威斯特法伦州", cities: ["科隆", "杜塞尔多夫", "多特蒙德", "波恩"]),
            Region(name: "汉堡", cities: ["汉堡"]),
            Region(name: "巴登-符腾堡州", cities: ["斯图加特", "卡尔斯鲁厄", "弗莱堡"]),
            Region(name: "黑森州", cities: ["法兰克福", "威斯巴登"]),
            Region(name: "下萨克森州", cities: ["汉诺威", "不伦瑞克"]),
            Region(name: "萨克森州", cities: ["德累斯顿", "莱比锡"]),
            Region(name: "石勒苏益格-荷尔斯泰因州", cities: ["基尔", "吕贝克"]),
            Region(name: "不来梅", cities: ["不来梅"]),
        ]),
        Country(name: "加拿大", regions: [
            Region(name: "安大略省", cities: ["多伦多", "渥太华", "密西沙加", "汉密尔顿"]),
            Region(name: "不列颠哥伦比亚省", cities: ["温哥华", "维多利亚", "本拿比"]),
            Region(name: "魁北克省", cities: ["蒙特利尔", "魁北克市"]),
            Region(name: "阿尔伯塔省", cities: ["卡尔加里", "埃德蒙顿"]),
            Region(name: "曼尼托巴省", cities: ["温尼伯"]),
            Region(name: "萨斯喀彻温省", cities: ["萨斯卡通", "里贾纳"]),
            Region(name: "新斯科舍省", cities: ["哈利法克斯"]),
            Region(name: "新不伦瑞克省", cities: ["弗雷德里克顿", "圣约翰"]),
            Region(name: "纽芬兰与拉布拉多省", cities: ["圣约翰斯"]),
        ]),
        Country(name: "澳大利亚", regions: [
            Region(name: "新南威尔士州", cities: ["悉尼", "纽卡斯尔", "卧龙岗"]),
            Region(name: "维多利亚州", cities: ["墨尔本", "吉朗"]),
            Region(name: "昆士兰州", cities: ["布里斯班", "黄金海岸", "凯恩斯"]),
            Region(name: "西澳大利亚州", cities: ["珀斯", "弗里曼特尔"]),
            Region(name: "南澳大利亚州", cities: ["阿德莱德"]),
            Region(name: "塔斯马尼亚州", cities: ["霍巴特", "朗塞斯顿"]),
            Region(name: "澳大利亚首都领地", cities: ["堪培拉"]),
        ]),
        Country(name: "新加坡", regions: [
            Region(name: "新加坡", cities: ["新加坡"]),
        ]),
        Country(name: "马来西亚", regions: [
            Region(name: "吉隆坡联邦直辖区", cities: ["吉隆坡"]),
            Region(name: "雪兰莪州", cities: ["莎阿南", "八打灵再也"]),
            Region(name: "槟城州", cities: ["乔治市"]),
            Region(name: "柔佛州", cities: ["新山"]),
            Region(name: "沙巴州", cities: ["亚庇", "山打根"]),
            Region(name: "砂拉越州", cities: ["古晋", "美里"]),
            Region(name: "马六甲州", cities: ["马六甲"]),
            Region(name: "森美兰州", cities: ["芙蓉"]),
            Region(name: "霹雳州", cities: ["怡保"]),
            Region(name: "吉打州", cities: ["亚罗士打"]),
            Region(name: "吉兰丹州", cities: ["哥打巴鲁"]),
            Region(name: "登嘉楼州", cities: ["瓜拉登嘉楼"]),
            Region(name: "彭亨州", cities: ["关丹"]),
            Region(name: "玻璃市州", cities: ["加央"]),
        ]),
        Country(name: "泰国", regions: [
            Region(name: "曼谷", cities: ["曼谷"]),
            Region(name: "清迈府", cities: ["清迈"]),
            Region(name: "普吉府", cities: ["普吉"]),
            Region(name: "春武里府", cities: ["芭堤雅", "是拉差"]),
            Region(name: "孔敬府", cities: ["孔敬"]),
            Region(name: "宋卡府", cities: ["合艾"]),
            Region(name: "清莱府", cities: ["清莱"]),
            Region(name: "素叻他尼府", cities: ["苏梅岛", "素叻他尼"]),
            Region(name: "大城府", cities: ["大城"]),
            Region(name: "北碧府", cities: ["北碧"]),
        ]),
        Country(name: "意大利", regions: [
            Region(name: "拉齐奥大区", cities: ["罗马"]),
            Region(name: "伦巴第大区", cities: ["米兰", "贝加莫"]),
            Region(name: "威尼托大区", cities: ["威尼斯", "维罗纳", "帕多瓦"]),
            Region(name: "托斯卡纳大区", cities: ["佛罗伦萨", "比萨", "锡耶纳"]),
            Region(name: "坎帕尼亚大区", cities: ["那不勒斯"]),
            Region(name: "西西里大区", cities: ["巴勒莫", "卡塔尼亚"]),
            Region(name: "皮埃蒙特大区", cities: ["都灵"]),
            Region(name: "利古里亚大区", cities: ["热那亚"]),
            Region(name: "艾米利亚-罗马涅大区", cities: ["博洛尼亚", "摩德纳"]),
            Region(name: "普利亚大区", cities: ["巴里"]),
        ]),
        Country(name: "西班牙", regions: [
            Region(name: "马德里自治区", cities: ["马德里"]),
            Region(name: "加泰罗尼亚", cities: ["巴塞罗那", "赫罗纳", "塔拉戈纳"]),
            Region(name: "安达卢西亚", cities: ["塞维利亚", "格拉纳达", "马拉加", "科尔多瓦"]),
            Region(name: "巴斯克自治区", cities: ["毕尔巴鄂", "圣塞巴斯蒂安"]),
            Region(name: "加利西亚", cities: ["拉科鲁尼亚", "圣地亚哥-德孔波斯特拉"]),
            Region(name: "瓦伦西亚自治区", cities: ["瓦伦西亚", "阿利坎特"]),
            Region(name: "巴利阿里群岛", cities: ["帕尔马"]),
            Region(name: "加那利群岛", cities: ["拉斯帕尔马斯", "圣克鲁斯-德特内里费"]),
        ]),
        Country(name: "荷兰", regions: [
            Region(name: "北荷兰省", cities: ["阿姆斯特丹", "哈勒姆"]),
            Region(name: "南荷兰省", cities: ["鹿特丹", "海牙", "莱顿", "代尔夫特"]),
            Region(name: "乌得勒支省", cities: ["乌得勒支"]),
            Region(name: "北布拉班特省", cities: ["埃因霍温", "布雷达", "蒂尔堡"]),
            Region(name: "海尔德兰省", cities: ["阿纳姆", "奈梅亨"]),
            Region(name: "林堡省", cities: ["马斯特里赫特"]),
            Region(name: "格罗宁根省", cities: ["格罗宁根"]),
            Region(name: "弗里斯兰省", cities: ["吕伐登"]),
        ]),
        Country(name: "新西兰", regions: [
            Region(name: "奥克兰大区", cities: ["奥克兰"]),
            Region(name: "惠灵顿大区", cities: ["惠灵顿"]),
            Region(name: "坎特伯雷大区", cities: ["基督城"]),
            Region(name: "奥塔哥大区", cities: ["但尼丁", "皇后镇"]),
            Region(name: "怀卡托大区", cities: ["哈密尔顿"]),
            Region(name: "丰盛湾大区", cities: ["陶朗加", "罗托鲁瓦"]),
            Region(name: "玛纳瓦图-旺加努伊大区", cities: ["北帕默斯顿"]),
            Region(name: "霍克斯湾大区", cities: ["内皮尔", "黑斯廷斯"]),
        ]),
    ]

    /// 英文设备语言下 CLGeocoder 回的国家名 → 中文名（地区/城市只按中文名匹配）。
    private static let countryEnglishAliases: [String: String] = [
        "United States": "美国", "Japan": "日本", "South Korea": "韩国",
        "United Kingdom": "英国", "France": "法国", "Germany": "德国",
        "Canada": "加拿大", "Australia": "澳大利亚", "Singapore": "新加坡",
        "Malaysia": "马来西亚", "Thailand": "泰国", "Italy": "意大利",
        "Spain": "西班牙", "Netherlands": "荷兰", "New Zealand": "新西兰",
        "China": "中国",
    ]

    /// 定位反查三元组 → 内嵌规范名。国家必中才返回；地区/城市未中时为空，
    /// 级联选择器按已命中的层级预选，未命中的层级由用户自填。
    static func match(country: String?, region: String?, city: String?) -> (country: String, region: String?, city: String?)? {
        guard let rawCountry = country, !rawCountry.isEmpty else { return nil }
        let countryName = countryEnglishAliases[rawCountry] ?? rawCountry
        guard let matchedCountry = countries.first(where: { normalize($0.name) == normalize(countryName) }) else { return nil }
        var matchedRegion: Region?
        if let rawRegion = region, !rawRegion.isEmpty {
            matchedRegion = matchedCountry.regions.first(where: { normalize($0.name) == normalize(rawRegion) })
        }
        var matchedCity: String?
        if let matchedRegion = matchedRegion {
            if let rawCity = city, !rawCity.isEmpty {
                matchedCity = matchedRegion.cities.first(where: { normalize($0) == normalize(rawCity) })
            }
            // 直辖市：locality 常为空，市本身就是地级市（cities 表里就是它自己）；
            // 没匹配到城市时直接用地区名当城市（北京／上海／天津／重庆）。
            if matchedCity == nil, matchedRegion.cities.contains(where: { normalize($0) == normalize(matchedRegion.name) }) {
                matchedCity = matchedRegion.name
            }
        }
        return (matchedCountry.name, matchedRegion?.name, matchedCity)
    }

    /// 去行政后缀再比对：特别行政区/自治区/自治州/省/市/县/区/盟/地区/州。
    private static func normalize(_ name: String) -> String {
        var result = name
        for suffix in ["特别行政区", "自治区", "自治州", "地区", "省", "市", "县", "区", "盟", "州"] {
            if result.hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
                break
            }
        }
        return result
    }
}
