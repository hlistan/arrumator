import CoreGraphics

/// Russian documents of Иван Тестов (Moscow).
enum RussianFixtures {
    static func all(cast: Cast, seed: UInt64) -> [Fixture] {
        [
            electricityBill(cast: cast, seed: seed),
            taxReturn(cast: cast, seed: seed),
            taxNotice(cast: cast, seed: seed),
            bankStatement(cast: cast, seed: seed),
            snilsCard(cast: cast, seed: seed),
            dischargeSummary(cast: cast, seed: seed),
            motorPolicy(cast: cast, seed: seed),
            saleContract(cast: cast, seed: seed),
            incomeStatement(cast: cast, seed: seed),
            registryExtract(cast: cast, seed: seed),
            telecomBillKOI8(cast: cast, seed: seed),
            employmentCertificateUTF8(cast: cast, seed: seed),
        ]
    }

    private static let fnsAccent = RGB(hex: 0x2F5597)
    private static let fnsFooter = "Федеральная налоговая служба · www.nalog.gov.ru · Личный кабинет налогоплательщика"
    private static let taxOffice = "Инспекция ФНС России № 28 по г. Москве"
    private static let monthlySalary = Money(125_000)
    private static let cadastralNumber = "77:01:0001001:1234"
    private static let plate = "Е001КХ777"

    // MARK: 20 Mosenergosbyt (scan)

    static func electricityBill(cast: Cast, seed: UInt64) -> Fixture {
        let file = "ru/20-mosenergosbyt-kvitanciya-2026-08.pdf"
        var fake = Fake(seed: seed, salt: file)
        let formed = Day(2026, 9, 3)
        let due = Day(2026, 9, 15)
        let dayUse = 167
        let nightUse = 69
        let dayPrevious = fake.int(12_000...15_000)
        let nightPrevious = fake.int(5_000...7_000)
        let dayCharge = Money(9, 59).times(Double(dayUse))
        let nightCharge = Money(3, 94).times(Double(nightUse))
        let total = dayCharge + nightCharge
        let companyAccount = fake.ruAccount(prefix: "40702810", bik: cast.sberbankBIK)
        let document = Document(
            info: DocumentInfo(title: "Счёт за электроэнергию август 2026", author: "АО «Мосэнергосбыт»",
                               subject: "Квитанция", created: formed),
            accent: RGB(hex: 0x00569C),
            footer: "АО «Мосэнергосбыт» · ИНН \(cast.mosenergosbyt.taxID) · 117312, г. Москва, ул. Примерная, д. 10 · www.mosenergosbyt.ru",
            pageNumbers: .ru,
            blocks: [
                .wordmark("Мосэнергосбыт", tagline: "Акционерное общество «Мосэнергосбыт»"),
                .title("Счёт за электроэнергию"),
                .subtitle("Квитанция за электроэнергию за август 2026 г."),
                .fields([
                    Field("Лицевой счёт", "\(fake.digitString(5))-\(fake.digitString(3))-\(fake.digitString(2))"),
                    Field("Плательщик", cast.ivan.fullName),
                    Field("Адрес", cast.ivan.address),
                    Field("Расчётный период", "август 2026 г."),
                    Field("Дата формирования", formed.ruNumeric),
                    Field("Оплатить до", due.ruNumeric),
                ]),
                .heading("Начисления"),
                .table(Table([Column("Услуга", 0.3), Column("Пред.", 0.12, .right), Column("Тек.", 0.12, .right),
                              Column("кВт·ч", 0.12, .right), Column("Тариф", 0.14, .right), Column("Сумма", 0.2, .right)],
                             rows: [
                                ["День (Т1)", "\(dayPrevious)", "\(dayPrevious + dayUse)", "\(dayUse)", "9,59", dayCharge.ru],
                                ["Ночь (Т2)", "\(nightPrevious)", "\(nightPrevious + nightUse)", "\(nightUse)", "3,94", nightCharge.ru],
                             ],
                             totals: [["Итого", "", "", "\(dayUse + nightUse)", "", total.ru]])),
                .banner("Итого к оплате: \(total.rub)"),
                .heading("Реквизиты для оплаты"),
                .fields([
                    Field("Получатель", "АО «Мосэнергосбыт»"),
                    Field("ИНН / КПП", "\(cast.mosenergosbyt.taxID) / 773601001"),
                    Field("Банк", "ПАО Сбербанк, г. Москва"),
                    Field("БИК", cast.sberbankBIK),
                    Field("Р/с", companyAccount),
                ]),
                .paragraph("Показания счётчика передавайте с 15 по 26 число месяца в личном кабинете на сайте mosenergosbyt.ru или в мобильном приложении."),
            ])
        return .filed(file, .ru, .pdfScan, core: true, category: "32", year: 2026, type: .invoice,
                      correspondent: "Mosenergosbyt", date: formed, title: "Квитанция за электроэнергию август 2026",
                      titleContains: ["электроэнергию", "август"], identifiers: [.ruINN(cast.mosenergosbyt.taxID)],
                      payload: .pdfScan(.document(document)))
    }

    // MARK: 21–22 FNS

    static func taxReturn(cast: Cast, seed: UInt64) -> Fixture {
        let file = "ru/21-fns-3ndfl-2025.pdf"
        var fake = Fake(seed: seed, salt: file)
        let filed = Day(2026, 4, 15)
        let ivan = cast.ivan
        let document = Document(
            info: DocumentInfo(title: "Декларация 3-НДФЛ за 2025 год", author: ivan.fullName,
                               subject: "Налоговая декларация по налогу на доходы физических лиц", created: filed),
            accent: fnsAccent, footer: fnsFooter, pageNumbers: .ru,
            blocks: [
                .wordmark("ФНС России", tagline: "Федеральная налоговая служба · Личный кабинет налогоплательщика"),
                .title("Налоговая декларация по налогу на доходы физических лиц (форма 3-НДФЛ)"),
                .subtitle("Титульный лист · отчётный налоговый период 2025 год"),
                .fields([
                    Field("ИНН", ivan.inn),
                    Field("Номер корректировки", "0"),
                    Field("Налоговый период (код)", "34"),
                    Field("Отчётный налоговый период (год)", "2025"),
                    Field("Представляется в налоговый орган (код)", "7728"),
                    Field("Код категории налогоплательщика", "760"),
                    Field("Фамилия, имя, отчество", ivan.fullName),
                    Field("Дата рождения", ivan.birthDate.ruNumeric),
                    Field("Документ, удостоверяющий личность", "21 – паспорт гражданина РФ, \(ivan.passport)"),
                    Field("Статус налогоплательщика", "1 – налоговый резидент РФ"),
                ]),
                .heading("Раздел 1. Сведения о суммах налога, подлежащих уплате (доплате) в бюджет или возврату из бюджета"),
                .table(Table([Column("Код строки", 0.14), Column("Показатель", 0.56), Column("Значение", 0.3, .right)],
                             rows: [
                                ["010", "Код бюджетной классификации", "18210102010011000110"],
                                ["020", "Код по ОКТМО", "45383000"],
                                ["030", "Сумма налога к уплате (доплате)", "0"],
                                ["050", "Сумма налога к возврату из бюджета", "39 000"],
                             ])),
                .heading("Приложение 7. Расчёт имущественных налоговых вычетов"),
                .table(Table([Column("Показатель", 0.7), Column("Сумма, руб.", 0.3, .right)],
                             rows: [
                                ["Объект: квартира, кадастровый номер \(cadastralNumber)", ""],
                                ["Доходы, облагаемые по ставке 13 %", Money(cents: monthlySalary.cents * 12).ru],
                                ["Остаток вычета, перенесённый с предыдущих лет", Money(300_000).ru],
                                ["Имущественный вычет, заявленный за 2025 год", Money(300_000).ru],
                                ["Сумма налога, удержанная налоговым агентом", Money(195_000).ru],
                             ])),
                .paragraph("Декларация подписана усиленной неквалифицированной электронной подписью налогоплательщика и направлена через личный кабинет налогоплательщика."),
                .heading("Квитанция о приёме"),
                .fields([
                    Field("Дата представления", filed.ruNumeric),
                    Field("Регистрационный номер", fake.reference(11)),
                    Field("Налоговый орган", "\(taxOffice) (код 7728)"),
                ]),
                .note("Достоверность и полноту сведений, указанных в настоящей декларации, подтверждаю. \(ivan.shortName), \(filed.ruNumeric)."),
            ])
        return .filed(file, .ru, .pdfText, core: true, category: "24", year: 2025, type: .taxReturn,
                      correspondent: "FNS", date: filed, title: "Декларация 3-НДФЛ за 2025",
                      titleContains: ["3-НДФЛ", "2025"], identifiers: [.ruINN(ivan.inn)],
                      acceptAlso: AcceptAlso(correspondent: ["ФНС", "ИФНС России № 28 по г. Москве"]),
                      payload: .pdfText(document))
    }

    static func taxNotice(cast: Cast, seed: UInt64) -> Fixture {
        let file = "ru/22-fns-uvedomlenie-2025.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 9, 1)
        let ivan = cast.ivan
        let propertyTax = Money(12_346)
        let vehicleTax = Money(1_272)
        let total = propertyTax + vehicleTax
        let number = fake.digitString(8)
        let document = Document(
            info: DocumentInfo(title: "Налоговое уведомление № \(number)", author: "ФНС России",
                               subject: "Налоговое уведомление за 2025 год", created: issued),
            accent: fnsAccent, footer: fnsFooter, pageNumbers: .ru,
            blocks: [
                .wordmark("ФНС России", tagline: taxOffice),
                .columns(left: [taxOffice, "117000, г. Москва, ул. Примерная, д. 5", "Код налогового органа: 7728"],
                         right: [ivan.fullName, ivan.address, "ИНН \(ivan.inn)"]),
                .title("Налоговое уведомление № \(number) от \(issued.ruNumeric)"),
                .subtitle("об уплате налогов за 2025 год"),
                .paragraph("\(taxOffice) уведомляет Вас о необходимости уплаты налогов, исчисленных в отношении принадлежащего Вам имущества за налоговый период 2025 года, не позднее 01.12.2026."),
                .heading("Расчёт налога на имущество физических лиц"),
                .table(Table([Column("Объект", 0.34), Column("База, руб.", 0.18, .right), Column("Доля", 0.1, .right),
                              Column("Ставка", 0.12, .right), Column("Месяцев", 0.12, .right), Column("Сумма, руб.", 0.14, .right)],
                             rows: [["Квартира \(cadastralNumber)", "12 345 678", "1", "0,1 %", "12/12", propertyTax.ru]])),
                .heading("Расчёт транспортного налога"),
                .table(Table([Column("Объект", 0.34), Column("Рег. знак", 0.18), Column("Мощность", 0.12, .right),
                              Column("Ставка", 0.12, .right), Column("Месяцев", 0.1, .right), Column("Сумма, руб.", 0.14, .right)],
                             rows: [["Автомобиль LADA Vesta", plate, "106 л.с.", "12", "12/12", vehicleTax.ru]])),
                .banner("Итого к уплате: \(total.rub)"),
                .fields([
                    Field("Срок уплаты", "не позднее 01.12.2026"),
                    Field("Уникальный идентификатор начисления", "18201770000\(fake.digitString(9))"),
                ]),
                .heading("Реквизиты для уплаты на единый налоговый счёт"),
                .fields([
                    Field("Получатель", cast.treasury.name),
                    Field("ИНН получателя", cast.treasury.taxID),
                    Field("Банк получателя", "Отделение Тула Банка России // УФК по Тульской области"),
                    Field("Казначейский счёт", "031006430000000\(fake.digitString(5))"),
                ]),
                .note("Налоговое уведомление размещено в личном кабинете налогоплательщика и считается полученным со дня, следующего за днём его размещения."),
            ])
        return .filed(file, .ru, .pdfText, core: true, category: "24", year: 2025, type: .taxAssessment,
                      correspondent: "FNS", date: issued, title: "Налоговое уведомление за 2025",
                      titleContains: ["Налоговое уведомление", "2025"],
                      identifiers: [.ruINN(ivan.inn), .ruINN(cast.treasury.taxID)],
                      acceptAlso: AcceptAlso(correspondent: ["ФНС", "ИФНС России № 28 по г. Москве"]),
                      payload: .pdfText(document))
    }

    // MARK: 23 Sberbank statement

    static func bankStatement(cast: Cast, seed: UInt64) -> Fixture {
        let file = "ru/23-sber-vypiska-2026-07.pdf"
        var fake = Fake(seed: seed, salt: file)
        let formed = Day(2026, 7, 31)
        let opening = fake.money(18_000...32_000)
        let operations: [(Int, String, String, Money)] = [
            (1, "Зарплата", "ООО «Ромашка», заработная плата", Money(85_000)),
            (3, "Супермаркеты", "ПЯТЁРОЧКА 1234 Москва", -fake.money(1_800...2_900)),
            (5, "ЖКХ", "Мосэнергосбыт, оплата по л/с", -fake.money(1_500...2_000)),
            (9, "Связь", "Ростелеком, интернет и ТВ", -Money(1_070)),
            (12, "Транспорт", "Пополнение карты «Тройка»", -Money(1_000)),
            (15, "Переводы", "Перевод по СБП, Пётр Сергеевич О.", -Money(5_000)),
            (20, "Рестораны", "КОФЕЙНЯ НА ТЕСТОВОЙ", -fake.money(300...600)),
            (25, "Зарплата", "ООО «Ромашка», аванс", Money(40_000)),
            (28, "Здоровье", "АПТЕКА ЗДОРОВЬЕ", -fake.money(500...1_200)),
        ]
        var balance = opening
        var credits = Money.zero
        var debits = Money.zero
        let rows: [[String]] = operations.map { day, category, description, amount in
            balance = balance + amount
            if amount < .zero { debits = debits - amount } else { credits = credits + amount }
            return [Day(2026, 7, day).ruNumeric, category, description, (amount < .zero ? "" : "+") + amount.ru, balance.ru]
        }
        let document = Document(
            info: DocumentInfo(title: "Выписка по счёту за июль 2026", author: "ПАО Сбербанк",
                               subject: "Выписка по счёту дебетовой карты", created: formed),
            accent: RGB(hex: 0x21A038),
            footer: "ПАО Сбербанк · ИНН \(cast.sberbank.taxID) · 117000, г. Москва, ул. Примерная, д. 19 · www.sberbank.ru",
            pageNumbers: .ru,
            blocks: [
                .wordmark("СберБанк", tagline: "ПАО Сбербанк"),
                .title("Выписка по счёту дебетовой карты"),
                .subtitle("Выписка по счёту за июль 2026 г."),
                .fields([
                    Field("Владелец счёта", cast.ivan.fullName),
                    Field("Номер счёта (р/с)", cast.ivanAccount),
                    Field("Карта", "МИР Классическая •• \(fake.digitString(4))"),
                    Field("Валюта счёта", "RUB – российский рубль"),
                    Field("Период выписки", "01.07.2026 – 31.07.2026"),
                    Field("Дата формирования", formed.ruNumeric),
                ]),
                .heading("Остаток и обороты"),
                .fields([
                    Field("Остаток на 01.07.2026", opening.rub),
                    Field("Всего пополнений", credits.rub),
                    Field("Всего списаний", debits.rub),
                    Field("Остаток на 31.07.2026", balance.rub),
                ]),
                .heading("Расшифровка операций"),
                .table(Table([Column("Дата", 0.13), Column("Категория", 0.15), Column("Описание", 0.42),
                              Column("Сумма, руб.", 0.15, .right), Column("Остаток", 0.15, .right)], rows: rows)),
                .heading("Реквизиты банка"),
                .fields([
                    Field("Банк получателя", "ПАО Сбербанк"),
                    Field("БИК", cast.sberbankBIK),
                    Field("Корр. счёт", "30101810\(fake.digitString(12))"),
                    Field("ИНН / КПП банка", "\(cast.sberbank.taxID) / 773601001"),
                ]),
                .note("Выписка сформирована в СберБанк Онлайн. Документ подписан электронной подписью банка и не требует печати."),
            ])
        return .filed(file, .ru, .pdfText, core: true, category: "21", year: 2026, type: .statement,
                      correspondent: "Sberbank", date: formed, title: "Выписка по счёту июль 2026",
                      titleContains: ["Выписка", "июль"], identifiers: [.ruINN(cast.sberbank.taxID)],
                      payload: .pdfText(document))
    }

    // MARK: 24 СНИЛС card (photo)

    static func snilsCard(cast: Cast, seed: UInt64) -> Fixture {
        let file = "ru/24-snils.jpg"
        var fake = Fake(seed: seed, salt: file)
        let registered = Day(2015, 6, 14)
        let green = RGB(hex: 0x1E4D2B)
        func label(_ text: String, _ x: CGFloat, _ y: CGFloat) -> CardElement {
            .text(text, x: x, y: y, size: 2.0, color: green)
        }
        func value(_ text: String, _ x: CGFloat, _ y: CGFloat) -> CardElement {
            .text(text, x: x, y: y, size: 3.0, bold: true, color: .ink)
        }
        let card = Card(
            size: CGSize(width: 90, height: 60), cornerRadius: 2.5,
            background: [RGB(0.73, 0.87, 0.71), RGB(0.82, 0.92, 0.77)],
            securityPrint: RGB(0.33, 0.55, 0.36),
            elements: [
                .text("РОССИЙСКАЯ ФЕДЕРАЦИЯ", x: 27, y: 2.5, size: 2.3, bold: true, color: green),
                .text("СТРАХОВОЕ СВИДЕТЕЛЬСТВО", x: 17, y: 6.5, size: 3.6, bold: true, color: green),
                .text("ОБЯЗАТЕЛЬНОГО ПЕНСИОННОГО СТРАХОВАНИЯ", x: 10, y: 11.5, size: 2.5, bold: true, color: green),
                .text(fake.snils(), x: 27, y: 16.5, size: 4.0, bold: true, color: .ink),
                label("Ф.И.О.", 5, 24), value(cast.ivan.surname, 26, 23.5),
                value(cast.ivan.givenName, 26, 28), value(cast.ivan.patronymic, 26, 32.5),
                label("Дата и место", 5, 38), label("рождения", 5, 40.5),
                value(cast.ivan.birthDate.ruWords, 26, 37.5), value("гор. Москва", 26, 41.5),
                label("Пол", 5, 46.5), value("мужской", 26, 46),
                label("Дата регистрации", 5, 52.5), value(registered.ruWords, 34, 52),
                .signature(CGRect(x: 66, y: 44, width: 20, height: 7)),
            ])
        let photo = Photo(subject: .card(card), format: .jpeg,
                          taken: DateTimeStamp(Day(2026, 2, 10), hour: 20, minute: 14, second: 55, utcOffsetMinutes: 180))
        return .filed(file, .ru, .imagePhoto, core: true, category: "11", year: nil, type: .idDocument,
                      correspondent: "SFR", date: registered, title: "Страховое свидетельство СНИЛС",
                      titleContains: ["Страховое", "свидетельство"], minBand: .review,
                      acceptAlso: AcceptAlso(correspondent: ["ПФР", "СФР", "Пенсионный фонд Российской Федерации"]),
                      payload: .photo(photo))
    }

    // MARK: 25 discharge summary (scan)

    static func dischargeSummary(cast: Cast, seed: UInt64) -> Fixture {
        let file = "ru/25-vypisnoy-epikriz.pdf"
        var fake = Fake(seed: seed, salt: file)
        let discharged = Day(2025, 11, 3)
        let ivan = cast.ivan
        let document = Document(
            info: DocumentInfo(title: "Выписной эпикриз", author: "ГКБ № 1", subject: "Медицинская документация", created: discharged),
            family: .serif, accent: .black, pageNumbers: .ru,
            blocks: [
                .strong("Департамент здравоохранения города Москвы"),
                .strong("ГБУЗ «Городская клиническая больница № 1» (ГКБ № 1)"),
                .note("117049, г. Москва, Больничный пр., д. 1 · Терапевтическое отделение № 2"),
                .title("ВЫПИСНОЙ ЭПИКРИЗ", alignment: .center),
                .subtitle("из медицинской карты стационарного больного № \(fake.int(10_000...29_999))/25", alignment: .center),
                .fields([
                    Field("Пациент", ivan.fullName),
                    Field("Дата рождения", ivan.birthDate.ruNumeric),
                    Field("Адрес", ivan.address),
                    Field("Полис ОМС", fake.digitString(16)),
                    Field("Находился на лечении", "с 27.10.2025 по 03.11.2025"),
                ]),
                .paragraph("Диагноз основной: J18.1 Внебольничная долевая пневмония нижней доли правого лёгкого, нетяжёлое течение."),
                .paragraph("Жалобы при поступлении: повышение температуры тела до 38,7 °C, кашель с мокротой, слабость, одышка при физической нагрузке."),
                .paragraph("Обследование: общий анализ крови от 27.10.2025 – лейкоциты 12,4 × 10^9/л, СОЭ 28 мм/ч; С-реактивный белок 64 мг/л. Рентгенография органов грудной клетки от 27.10.2025: инфильтрация в нижней доле правого лёгкого. Контрольная рентгенография от 02.11.2025: положительная динамика."),
                .paragraph("Проведённое лечение: цефтриаксон 2 г внутривенно 1 раз в сутки № 7, азитромицин 500 мг 1 раз в сутки № 3, амброксол, инфузионная терапия."),
                .paragraph("Состояние при выписке удовлетворительное. Температура тела нормальная, дыхание везикулярное, хрипов нет."),
                .paragraph("Рекомендации: наблюдение терапевта по месту жительства; контрольная рентгенография органов грудной клетки через 4 недели; ограничение физических нагрузок в течение 2 недель."),
                .fields([Field("Дата выписки", discharged.ruNumeric)]),
                .columns(left: ["Лечащий врач", "Петрова А. В. __________"], right: ["Заведующий отделением", "Сидоров К. Л. __________"]),
            ])
        return .filed(file, .ru, .pdfScan, core: true, category: "41", year: 2025, type: .medicalReport,
                      correspondent: "ГКБ № 1", date: discharged, title: "Выписной эпикриз",
                      titleContains: ["Выписной", "эпикриз"],
                      acceptAlso: AcceptAlso(correspondent: ["Городская клиническая больница № 1", "GKB 1"]),
                      payload: .pdfScan(.document(document)))
    }

    // MARK: 26 ОСАГО

    static func motorPolicy(cast: Cast, seed: UInt64) -> Fixture {
        let file = "ru/26-osago-polis.pdf"
        var fake = Fake(seed: seed, salt: file)
        let concluded = Day(2026, 5, 14)
        let ivan = cast.ivan
        let premium = fake.money(7_500...9_500)
        let document = Document(
            info: DocumentInfo(title: "Полис ОСАГО", author: "СПАО «Ингосстрах»", subject: "Электронный страховой полис", created: concluded),
            accent: RGB(hex: 0x0A3D91),
            footer: "\(cast.ingosstrakh.name) · ИНН \(cast.ingosstrakh.taxID) · 115035, г. Москва, ул. Примерная, д. 12 · www.ingos.ru",
            pageNumbers: .ru,
            blocks: [
                .wordmark("ИНГОССТРАХ", tagline: "Страховое публичное акционерное общество «Ингосстрах»"),
                .title("Страховой полис ОСАГО"),
                .subtitle("обязательного страхования гражданской ответственности владельцев транспортных средств"),
                .fields([
                    Field("Номер полиса", "ХХХ \(fake.reference(10))"),
                    Field("Форма", "электронный полис"),
                    Field("Срок страхования", "с 00 ч 00 мин 15.05.2026 по 24 ч 00 мин 14.05.2027"),
                    Field("Страхователь", ivan.fullName),
                    Field("Собственник ТС", ivan.fullName),
                ]),
                .heading("Транспортное средство"),
                .fields([
                    Field("Марка, модель", "LADA Vesta"),
                    Field("VIN", "XTAGFK330MY\(fake.digitString(6))"),
                    Field("Государственный рег. знак", plate),
                    Field("Свидетельство о регистрации ТС", "77 \(fake.int(10...99)) \(fake.digitString(6))"),
                    Field("Цель использования", "личная"),
                ]),
                .heading("Лица, допущенные к управлению"),
                .table(Table([Column("№", 0.06), Column("Фамилия, имя, отчество", 0.5), Column("Водительское удостоверение", 0.3),
                              Column("Стаж с", 0.14, .right)],
                             rows: [["1", ivan.fullName, "77 \(fake.int(10...99)) \(fake.digitString(6))", "2006"]])),
                .fields([
                    Field("Страховая премия", premium.rub),
                    Field("Дата заключения договора", concluded.ruNumeric),
                    Field("Дата выдачи полиса", concluded.ruNumeric),
                ]),
                .paragraph("Страховая сумма по риску причинения вреда имуществу – 400 000 руб., вреда жизни и здоровью – 500 000 руб. При ДТП оформите извещение о дорожно-транспортном происшествии и сообщите страховщику."),
                .note("Полис оформлен в электронном виде и подписан усиленной квалифицированной электронной подписью страховщика."),
            ])
        return .filed(file, .ru, .pdfText, core: true, category: "63", year: nil, type: .policy,
                      correspondent: "Ingosstrakh", date: concluded, title: "Полис ОСАГО",
                      titleContains: ["ОСАГО"], identifiers: [.ruINN(cast.ingosstrakh.taxID)],
                      payload: .pdfText(document))
    }

    // MARK: 27 sale contract (DOCX)

    static func saleContract(cast: Cast, seed: UInt64) -> Fixture {
        let file = "ru/27-dogovor-kupli-prodazhi.docx"
        var fake = Fake(seed: seed, salt: file)
        let signed = Day(2018, 11, 20)
        let seller = cast.petr
        let buyer = cast.ivan
        let document = Document(
            info: DocumentInfo(title: "Договор купли-продажи квартиры", author: seller.fullName,
                               subject: "Купля-продажа недвижимости", created: signed),
            family: .serif, accent: .black,
            blocks: [
                .title("ДОГОВОР КУПЛИ-ПРОДАЖИ КВАРТИРЫ", alignment: .center),
                .columns(left: ["г. Москва"], right: ["двадцатое ноября 2018 года"]),
                .paragraph("Гражданин Российской Федерации \(seller.fullName), \(seller.birthDate.ruNumeric) года рождения, паспорт \(seller.passport), ИНН \(seller.inn), зарегистрированный по адресу: \(seller.address), именуемый в дальнейшем «Продавец», с одной стороны, и гражданин Российской Федерации \(buyer.fullName), \(buyer.birthDate.ruNumeric) года рождения, паспорт \(buyer.passport), ИНН \(buyer.inn), именуемый в дальнейшем «Покупатель», с другой стороны, заключили настоящий договор о нижеследующем."),
                .heading("1. Предмет договора"),
                .paragraph("1.1. Продавец продал, а Покупатель купил в собственность квартиру, находящуюся по адресу: \(buyer.address), кадастровый номер \(cadastralNumber), общей площадью 54,3 кв. м, расположенную на 5 этаже многоквартирного дома."),
                .paragraph("1.2. Квартира принадлежит Продавцу на праве собственности, о чём в Едином государственном реестре недвижимости 10.03.2015 сделана запись регистрации № 77-77/011-77/011/\(fake.digitString(3))/2015-\(fake.int(100...999))/2."),
                .paragraph("1.3. Продавец гарантирует, что квартира никому не продана, не подарена, не заложена, в споре и под арестом не состоит."),
                .heading("2. Цена и порядок расчётов"),
                .paragraph("2.1. Стоимость квартиры составляет 9 500 000 (девять миллионов пятьсот тысяч) рублей 00 копеек."),
                .paragraph("2.2. Расчёт между сторонами производится с использованием безотзывного покрытого аккредитива, открытого Покупателем в ПАО Сбербанк, в течение пяти рабочих дней после государственной регистрации перехода права собственности."),
                .heading("3. Передача квартиры"),
                .paragraph("3.1. Квартира передаётся Продавцом Покупателю по передаточному акту в течение десяти дней после государственной регистрации перехода права собственности."),
                .heading("4. Заключительные положения"),
                .paragraph("4.1. Право собственности на квартиру возникает у Покупателя с момента государственной регистрации перехода права собственности в Едином государственном реестре недвижимости (Росреестр)."),
                .paragraph("4.2. Договор составлен в двух экземплярах, имеющих одинаковую юридическую силу, по одному для каждой из сторон."),
                .heading("Подписи сторон"),
                .columns(left: ["Продавец", "", "____________ \(seller.shortName)"], right: ["Покупатель", "", "____________ \(buyer.shortName)"]),
            ])
        return .filed(file, .ru, .docx, core: false, category: "31", year: nil, type: .contract,
                      correspondent: "Пётр Образцов", date: signed, title: "Договор купли-продажи квартиры",
                      titleContains: ["купли-продажи", "квартиры"],
                      identifiers: [.ruINN(seller.inn), .ruINN(buyer.inn)], minBand: .review,
                      acceptAlso: AcceptAlso(correspondent: [seller.fullName, "Petr Obraztsov"]),
                      payload: .docx(document))
    }

    // MARK: 28 income statement (2-НДФЛ)

    static func incomeStatement(cast: Cast, seed: UInt64) -> Fixture {
        let file = "ru/28-spravka-2ndfl-2025.pdf"
        let issued = Day(2026, 2, 10)
        let ivan = cast.ivan
        let yearly = Money(cents: monthlySalary.cents * 12)
        let tax = yearly.percent(13)
        let document = Document(
            info: DocumentInfo(title: "Справка о доходах и суммах налога физического лица за 2025 год", author: "ООО «Ромашка»",
                               subject: "Справка о доходах", created: issued),
            accent: RGB(hex: 0x333333), pageNumbers: .ru,
            blocks: [
                .title("Справка о доходах и суммах налога физического лица", alignment: .center),
                .subtitle("за 2025 год от \(issued.ruNumeric)", alignment: .center),
                .heading("1. Данные о налоговом агенте"),
                .fields([
                    Field("Налоговый агент", cast.romashka.name),
                    Field("ИНН / КПП", "\(cast.romashka.taxID) / 772801001"),
                    Field("Код по ОКТМО", "45383000"),
                    Field("Форма реорганизации", "–"),
                ]),
                .heading("2. Данные о физическом лице – получателе дохода"),
                .fields([
                    Field("ИНН в Российской Федерации", ivan.inn),
                    Field("Фамилия, имя, отчество", ivan.fullName),
                    Field("Статус налогоплательщика", "1"),
                    Field("Дата рождения", ivan.birthDate.ruNumeric),
                    Field("Гражданство (код страны)", "643"),
                    Field("Код вида документа", "21"),
                    Field("Серия и номер документа", ivan.passport),
                ]),
                .heading("3. Доходы, облагаемые по ставке 13 %"),
                .table(Table([Column("Месяц", 0.16), Column("Код дохода", 0.18), Column("Сумма дохода", 0.24, .right),
                              Column("Код вычета", 0.18, .right), Column("Сумма вычета", 0.24, .right)],
                             rows: (1...12).map { [String(format: "%02d", $0), "2000", monthlySalary.ru, "", ""] })),
                .heading("5. Общие суммы дохода и налога"),
                .fields([
                    Field("Общая сумма дохода", yearly.ru),
                    Field("Налоговая база", yearly.ru),
                    Field("Сумма налога исчисленная", tax.ru),
                    Field("Сумма налога удержанная", tax.ru),
                    Field("Сумма налога, излишне удержанная", "0,00"),
                ]),
                .columns(left: ["Налоговый агент", "Генеральный директор"], right: ["", "____________ Ромашкин А. А."]),
            ])
        return .filed(file, .ru, .pdfText, core: false, category: "52", year: 2026, type: .payslip,
                      correspondent: "ООО Ромашка", date: issued, title: "Справка о доходах за 2025",
                      titleContains: ["доходах", "2025"],
                      identifiers: [.ruINN(cast.romashka.taxID), .ruINN(ivan.inn)],
                      acceptAlso: AcceptAlso(yearFolder: ["2025"], docType: [.attestation],
                                             correspondent: ["ООО «Ромашка»", "OOO Romashka"]),
                      payload: .pdfText(document))
    }

    // MARK: 29 ЕГРН extract

    static func registryExtract(cast: Cast, seed: UInt64) -> Fixture {
        let file = "ru/29-egrn-vypiska.pdf"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2018, 12, 3)
        let document = Document(
            info: DocumentInfo(title: "Выписка из ЕГРН", author: "Росреестр", subject: "Выписка из Единого государственного реестра недвижимости", created: issued),
            accent: RGB(hex: 0x1D5AA8),
            footer: "Федеральная служба государственной регистрации, кадастра и картографии · rosreestr.gov.ru",
            pageNumbers: .ru,
            blocks: [
                .strong("Филиал федерального государственного бюджетного учреждения «Федеральная кадастровая палата Федеральной службы государственной регистрации, кадастра и картографии» по Москве"),
                .title("Выписка из ЕГРН", alignment: .center),
                .subtitle("Выписка из Единого государственного реестра недвижимости об основных характеристиках и зарегистрированных правах на объект недвижимости", alignment: .center),
                .fields([
                    Field("Дата", issued.ruNumeric),
                    Field("Номер", "99/2018/\(fake.reference(9))"),
                ]),
                .paragraph("На основании запроса от 30.11.2018, поступившего на рассмотрение 30.11.2018, сообщаем, что согласно записям Единого государственного реестра недвижимости:"),
                .heading("Раздел 1. Сведения об основных характеристиках объекта недвижимости"),
                .fields([
                    Field("Кадастровый номер", cadastralNumber),
                    Field("Номер кадастрового квартала", "77:01:0001001"),
                    Field("Дата присвоения номера", "15.06.2012"),
                    Field("Адрес", cast.ivan.address),
                    Field("Площадь, м²", "54,3"),
                    Field("Назначение", "Жилое помещение"),
                    Field("Наименование", "Квартира"),
                    Field("Номер этажа", "5"),
                    Field("Кадастровая стоимость, руб.", "12 345 678,90"),
                ]),
                .heading("Раздел 2. Сведения о зарегистрированных правах"),
                .fields([
                    Field("Правообладатель", cast.ivan.fullName),
                    Field("Вид права", "Собственность"),
                    Field("Номер регистрации", "\(cadastralNumber)-77/011/2018-3"),
                    Field("Дата регистрации", issued.ruNumeric),
                    Field("Ограничение прав", "не зарегистрировано"),
                ]),
                .note("Выписка выдана Филиалом ФГБУ «ФКП Росреестра» по Москве. Государственный регистратор: Иванова Е. П."),
            ])
        return .filed(file, .ru, .pdfText, core: false, category: "31", year: nil, type: .certificate,
                      correspondent: "Rosreestr", date: issued, title: "Выписка из ЕГРН",
                      titleContains: ["Выписка", "ЕГРН"], minBand: .check,
                      acceptAlso: AcceptAlso(correspondent: ["Росреестр", "ФКП Росреестра"]),
                      payload: .pdfText(document))
    }

    // MARK: 30 Rostelecom bill (KOI8-R text), 31 employment certificate (UTF-8 text)

    static func telecomBillKOI8(cast: Cast, seed: UInt64) -> Fixture {
        let file = "ru/30-rostelecom-schet-koi8r.txt"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 8, 5)
        let account = fake.reference(12)
        let total = Money(1_070)
        let vat = Money(cents: Int((Double(total.cents) * 22 / 122).rounded()))
        // KOI8-R has no "№", guillemets or dashes; the text sticks to what 1990s mail gateways could carry.
        let text = """
            ПАО "Ростелеком"
            Макрорегиональный филиал "Центр"
            ИНН \(cast.rostelecom.taxID)  КПП 770701001

            СЧЕТ N \(fake.reference(10)) от \(issued.ruNumeric)
            за услуги связи за июль 2026 г.

            Лицевой счет: \(account)
            Абонент: \(cast.ivan.fullName)
            Адрес: \(cast.ivan.address)

            Начислено за период 01.07.2026 - 31.07.2026:
              Домашний интернет, тариф "Технологичный" 500 Мбит/с ....  750,00 руб.
              Интерактивное ТВ, пакет "Базовый" .......................  320,00 руб.
              ------------------------------------------------------------------
              Итого начислено:                                          \(total.ru) руб.
              в т.ч. НДС 22%:                                             \(vat.ru) руб.
              Задолженность на начало периода:                              0,00 руб.

            К ОПЛАТЕ: \(total.rub)
            Оплатить до: 25.08.2026

            Оплатить счет можно в личном кабинете на сайте rt.ru, в приложении
            "Мой Ростелеком" и в отделениях банков.
            Служба поддержки: 8 800 000-00-00

            Это письмо сформировано автоматически, отвечать на него не нужно.

            """
        return .filed(file, .ru, .text, core: false, category: "33", year: 2026, type: .invoice,
                      correspondent: "Rostelecom", date: issued, title: "Счет за услуги связи июль 2026",
                      titleContains: ["Счет", "июль"], identifiers: [.ruINN(cast.rostelecom.taxID)], minBand: .review,
                      invalidIdentifiers: [.ruINN(account)], warnings: [.encodingGuessed], encoding: .koi8r,
                      payload: .text(text, .koi8r))
    }

    static func employmentCertificateUTF8(cast: Cast, seed: UInt64) -> Fixture {
        let file = "ru/31-spravka-s-mesta-raboty.txt"
        var fake = Fake(seed: seed, salt: file)
        let issued = Day(2026, 3, 16)
        let text = """
            Общество с ограниченной ответственностью «Ромашка»
            ИНН \(cast.romashka.taxID) / КПП 772801001
            125000, г. Москва, ул. Примерная, д. 15, офис 301
            Тел.: +7 495 000-00-00, e-mail: hr@romashka.example

            Исх. № \(fake.int(20...90))-К от \(issued.ruNumeric)

                                     СПРАВКА С МЕСТА РАБОТЫ

            Дана Тестову Ивану Ивановичу, \(cast.ivan.birthDate.ruNumeric) года рождения, в том, что он действительно
            работает в ООО «Ромашка» с 01.03.2021 по настоящее время в должности ведущего
            инженера-программиста (трудовой договор № 12/21 от 01.03.2021, основное место
            работы, полная занятость).

            Среднемесячная заработная плата за последние 6 месяцев составляет \(monthlySalary.ru) (сто
            двадцать пять тысяч) рублей 00 копеек до удержания НДФЛ.

            Справка выдана для предъявления по месту требования.

            Генеральный директор                                    А. А. Ромашкин
            Главный бухгалтер                                       О. П. Цветкова
            М. П.

            """
        return .filed(file, .ru, .text, core: false, category: "51", year: nil, type: .attestation,
                      correspondent: "ООО Ромашка", date: issued, title: "Справка с места работы",
                      titleContains: ["Справка", "места работы"], identifiers: [.ruINN(cast.romashka.taxID)],
                      minBand: .review, acceptAlso: AcceptAlso(correspondent: ["ООО «Ромашка»", "OOO Romashka"]),
                      encoding: .utf8, payload: .text(text, .utf8))
    }
}
