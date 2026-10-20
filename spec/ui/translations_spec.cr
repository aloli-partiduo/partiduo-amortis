# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Traductions des écrans de l'extension (ADR-005 D7) : chaque route de
# `/ext/AMORTIS/` servie en `GET` (liste tirée du routeur de Marten),
# obtenue en fr, en et nl par un administrateur, sur un registre varié
# (immobilisation en service dépréciée, composant, immobilisation pas
# encore en service, véhicule cédé dont la sortie reste à passer,
# écriture d'inventaire passée, acquisition à inscrire). Contrôle de
# l'interface (`PartiduoUi::Translations`) : ni marqueur de traduction
# absente, ni clé brute, ni interpolation non résolue, et toute route
# atteinte par les liens des pages.

private alias S = Amortis::SpecSupport
private alias Api = Amortis::Api
private alias Acc = Partiduo::Api::Accounting

describe "Traductions des écrans AMORTIS (fr, en, nl)" do
  it "rend chaque écran dans chaque langue, sans clé absente, brute ni interpolation non résolue" do
    S.activate
    browser = PartiduoUi::Books.admin
    PartiduoUi::Reference.fiscal_year(2025)
    PartiduoUi::Reference.fiscal_year(2027)
    S.user("bruno@example.com", "Bruno")

    computer = S.asset("Ordinateur", "2183", "1800", "2025-02-10", months: 36)
    Api.add_impairment(S.accountant, computer.id, Api::ImpairmentInput.new(S.date("2026-11-30"), S.d("300"), "Casse")).value!
    S.asset("Disque dur", "2183", "200", "2025-02-10", months: 36, parent_id: computer.id)
    S.asset("Machine en commande", "2154", "5000", "2026-09-01", service: nil, method: "degressive")
    van = S.asset("Fourgonnette", "2182", "20000", "2025-03-01", months: 60)
    Api.dispose(S.accountant, van.id, Api::DisposalInput.new(S.date("2026-08-31"), "sale", S.d("12000"))).value!
    Api.post_depreciation(S.accountant, S.fiscal_year(2025).id).value!
    # Acquisition passée au journal, pas encore inscrite au registre.
    S.account("2183")
    lines = [Acc::EntryLineInput.new("2183", Acc::Side::Debit, S.d("2400"), label: "Serveur"),
             Acc::EntryLineInput.new("400", Acc::Side::Credit, S.d("2400"))]
    Acc.post_entry(S.system, Acc::EntryInput.new(ledger_id: S.misc_ledger.id, date: S.date("2026-05-04"), lines: lines)).value!

    explorer = PartiduoUi::Translations::Explorer.new(&.name.starts_with?("amortis:"))
    explorer.crawl(browser, "AMORTIS")
    puts "\nTraductions de AMORTIS : #{explorer.report}"
    (explorer.failures + explorer.unreached.map { |route| "route jamais atteinte : #{route}" }).should eq([] of String)
  end
end
