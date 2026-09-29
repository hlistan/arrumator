/// A fake person living in Portugal.
struct PortugueseResident: Sendable {
    let name: String
    let nif: String
    let street: String
    let postcode: String
    let iban: String
    var address: String { "\(street), \(postcode)" }
}

/// A fake Russian citizen, named in the usual surname–given name–patronymic order.
struct RussianCitizen: Sendable {
    let surname: String
    let givenName: String
    let patronymic: String
    let inn: String
    let birthDate: Day
    let address: String
    let passport: String
    var fullName: String { "\(surname) \(givenName) \(patronymic)" }
    /// "Тестов И. И."
    var shortName: String { "\(surname) \(givenName.prefix(1)). \(patronymic.prefix(1))." }
}

/// A company or public body with its (fake) tax number.
struct Organisation: Sendable {
    let name: String
    let taxID: String
}

/// People and organisations that recur across fixtures, generated once from the corpus seed so that, for
/// example, the landlord's NIF on the lease matches the one on every rent receipt.
struct Cast: Sendable {
    // Portugal
    let maria: PortugueseResident
    let mariaNISS: String
    let mariaBirthDate: Day
    let mariaSNSNumber: String
    let joao: PortugueseResident
    let edp: Organisation
    let meo: Organisation
    let millennium: Organisation
    let unilabs: Organisation
    let multicare: Organisation
    let continente: Organisation
    let pharmacy: Organisation
    let plumber: Organisation

    // Russia
    let ivan: RussianCitizen
    let petr: RussianCitizen
    let mosenergosbyt: Organisation
    let sberbank: Organisation
    let sberbankBIK: String
    let ivanAccount: String
    let ingosstrakh: Organisation
    let romashka: Organisation
    let rostelecom: Organisation
    let treasury: Organisation

    // United Kingdom / anywhere
    let alexName = "Alex Sample"
    let alexEmail = "alex.sample@example.com"
    /// HMRC's published example National Insurance number.
    let alexNINumber = "QQ 12 34 56 C"
    let alexWiseIBAN: String

    init(seed: UInt64) {
        var fake = Fake(seed: seed, salt: "cast")
        maria = PortugueseResident(name: "Maria Exemplo", nif: Fake.canonicalNIF, street: "Rua Exemplo 12, 3.º Esq.",
                                   postcode: "1000-001 Lisboa", iban: Fake.canonicalIBAN)
        mariaNISS = fake.niss()
        mariaBirthDate = Day(1990, 5, 14)
        mariaSNSNumber = fake.reference(9)
        joao = PortugueseResident(name: "João Exemplo", nif: fake.ptNIF(firstDigit: 2), street: "Avenida Exemplo 100, 2.º Dto.",
                                  postcode: "1050-001 Lisboa", iban: fake.portugueseIBAN(bank: "0035"))
        edp = Organisation(name: "EDP Comercial – Comercialização de Energia, S.A.", taxID: fake.ptNIF(firstDigit: 5))
        meo = Organisation(name: "MEO – Serviços de Comunicações e Multimédia, S.A.", taxID: fake.ptNIF(firstDigit: 5))
        millennium = Organisation(name: "Banco Comercial Português, S.A.", taxID: fake.ptNIF(firstDigit: 5))
        unilabs = Organisation(name: "Unilabs Portugal, S.A.", taxID: fake.ptNIF(firstDigit: 5))
        multicare = Organisation(name: "Multicare – Seguros de Saúde, S.A.", taxID: fake.ptNIF(firstDigit: 5))
        continente = Organisation(name: "Modelo Continente Hipermercados, S.A.", taxID: fake.ptNIF(firstDigit: 5))
        pharmacy = Organisation(name: "Farmácia Central Exemplo", taxID: fake.ptNIF(firstDigit: 5))
        plumber = Organisation(name: "Canalizações Exemplo, Lda.", taxID: fake.ptNIF(firstDigit: 5))

        ivan = RussianCitizen(surname: "Тестов", givenName: "Иван", patronymic: "Иванович",
                              inn: fake.ruINN(region: 77, organisation: false), birthDate: Day(1985, 3, 12),
                              address: "г. Москва, ул. Тестовая, д. 1, кв. 10",
                              passport: "45 \(String(format: "%02d", fake.int(1...19))) \(fake.digitString(6))")
        petr = RussianCitizen(surname: "Образцов", givenName: "Пётр", patronymic: "Сергеевич",
                              inn: fake.ruINN(region: 77, organisation: false), birthDate: Day(1970, 7, 5),
                              address: "г. Москва, ул. Образцовая, д. 7, кв. 3",
                              passport: "45 \(String(format: "%02d", fake.int(1...19))) \(fake.digitString(6))")
        mosenergosbyt = Organisation(name: "АО «Мосэнергосбыт»", taxID: fake.ruINN(region: 77, organisation: true))
        sberbank = Organisation(name: "ПАО Сбербанк", taxID: fake.ruINN(region: 77, organisation: true))
        sberbankBIK = "0445" + fake.digitString(5)
        ivanAccount = fake.ruAccount(prefix: "40817810", bik: sberbankBIK)
        ingosstrakh = Organisation(name: "СПАО «Ингосстрах»", taxID: fake.ruINN(region: 77, organisation: true))
        romashka = Organisation(name: "ООО «Ромашка»", taxID: fake.ruINN(region: 77, organisation: true))
        rostelecom = Organisation(name: "ПАО «Ростелеком»", taxID: fake.ruINN(region: 77, organisation: true))
        treasury = Organisation(name: "Казначейство России (ФНС России)", taxID: fake.ruINN(region: 77, organisation: true))

        alexWiseIBAN = fake.belgianIBAN(bank: "967")
    }
}
