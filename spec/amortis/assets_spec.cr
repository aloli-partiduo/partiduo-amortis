# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Amortis::SpecSupport
private alias Api = Amortis::Api
private alias Acc = Partiduo::Api::Accounting

private def asset_input(label : String = "Ordinateur", account : String = "2183", gross : String = "1800",
                        day : String = "2026-02-10", **options) : Api::AssetInput
  Api::AssetInput.new(label: label, asset_account: account, acquired_on: S.date(day), gross_value: S.d(gross),
    in_service_on: S.date(day), life_months: 36)
    .copy_with(**options)
end

describe "Registre des immobilisations (D-AMO-003, D-AMO-007, D-AMO-012)" do
  it "inscrit une immobilisation : numéro suivant, comptes d'amortissements et de dépréciations déduits et créés" do
    S.setup
    S.account("2183", "Matériel de bureau et informatique")
    view = Api.create_asset(S.accountant, asset_input).value!
    view.code.should eq("IMM-00001")
    {view.depreciation_account, view.impairment_account, view.expense_account}.should eq({"28183", "29183", "6811"})
    view.expense_account_default.should be_true
    view.rubric.should eq("office")
    view.status.should eq("in_service")
    Acc.account(S.system, "28183").kind.should eq(Acc::AccountKind::AssetContra)
    Acc.account(S.system, "28183").label.should contain("Matériel de bureau")
    Api.create_asset(S.accountant, asset_input(label: "Écran")).value!.code.should eq("IMM-00002")
    Api.assets(S.reader).map(&.code).should eq(["IMM-00001", "IMM-00002"])
    Api.assets(S.reader, Api::AssetQuery.new(search: "écran")).map(&.label).should eq(["Écran"])
  end

  it "refuse une saisie incohérente avec des erreurs par champ" do
    S.setup
    S.account("2183")
    keys = ->(input : Api::AssetInput) { Api.check_asset(S.accountant, input).error_keys.sort }
    keys.call(asset_input(label: " ", gross: "0", residual_value: S.d("-1"))).should eq([
      "amortis.errors.asset.gross_value.positive", "amortis.errors.asset.label.blank", "amortis.errors.asset.residual_value.range",
    ])
    keys.call(asset_input(account: "28183")).should eq(["amortis.errors.asset_account.invalid"])
    keys.call(asset_input(account: "2999")).should eq(["amortis.errors.asset_account.invalid"])
    keys.call(asset_input(account: "2154")).should eq(["amortis.errors.account.missing"])
    keys.call(asset_input(life_months: 0)).should eq(["amortis.errors.asset.life_months.range"])
    keys.call(asset_input(in_service_on: S.date("2026-01-01"))).should eq(["amortis.errors.asset.in_service_on.before_acquisition"])
    keys.call(asset_input(method: "degressive", life_months: 24)).should eq(["amortis.errors.degressive.too_short"])
    keys.call(asset_input(fiscal_method: "degressive", fiscal_life_months: 60, new_asset: false))
      .should eq(["amortis.errors.degressive.used_asset"])
    keys.call(asset_input(fiscal_method: "linear")).should eq(["amortis.errors.asset.life_months.range"])
    keys.call(asset_input(method: "sum")).should eq(["amortis.errors.choice.invalid"])
    first = S.asset("Ordinateur", "2183", "1800", "2026-02-10", months: 36)
    keys.call(asset_input(code: first.code.downcase)).should eq(["amortis.errors.asset.code.taken"])
    reader = S.actor("bruno@example.com", [Api::READ, Api::WRITE, "accounting.account.read"])
    Api.check_asset(reader, asset_input(account: "2183", depreciation_account: "281839", impairment_account: "29183"))
      .errors.map { |error| {error.field, error.key} }.should eq([{"depreciation_account", "amortis.errors.account.missing"}])
  end

  it "rattache des composants à leur structure, sans composant de composant" do
    S.setup
    building = S.asset("Entrepôt", "213", "300000", "2026-01-01", months: 480)
    roof = S.asset("Toiture", "213", "60000", "2026-01-01", months: 240, parent_id: building.id)
    roof.parent_code.should eq(building.code)
    Api.asset(S.reader, building.id).component_count.should eq(1)
    Api.components(S.reader, building.id).map(&.label).should eq(["Toiture"])
    Api.check_asset(S.accountant, asset_input(account: "213", parent_id: roof.id)).error_keys
      .should eq(["amortis.errors.asset.parent.nested"])
    Api.assets(S.reader, Api::AssetQuery.new(include_components: false)).map(&.label).should eq(["Entrepôt"])
    Api.delete_asset(S.accountant, building.id).success?.should be_true
    Api.assets(S.reader).should be_empty
  end

  it "rend le tableau d'amortissement par exercice, avec le plan fiscal et le dérogatoire" do
    S.setup
    view = S.asset("Presse", "2154", "10000", "2026-04-15", fiscal_method: "degressive", fiscal_months: 60)
    view.coefficient.should eq(S.d("1.75"))
    view.rate.should eq(S.d("35"))
    schedule = Api.schedule(S.reader, view.id)
    schedule.derogatory.should be_true
    schedule.rows.map { |row| {row.exercise.label, row.accounting.to_s, row.fiscal.to_s, row.derogatory.to_s} }.first(2)
      .should eq([{"2026", "1430.14", "2625.0", "1194.86"}, {"2027", "2000.0", "2581.25", "581.25"}])
    schedule.rows.first.exercise.fiscal_year_id.should eq(S.fiscal_year(2026).id)
    schedule.rows.last.exercise.fiscal_year_id.should be_nil
    schedule.rows.first.posted?.should be_false
    view.net_value.should eq(S.d("8569.86"))
    view.derogatory_cumul.should eq(S.d("1194.86"))
  end

  it "prévisualise le plan d'une saisie non enregistrée" do
    S.setup
    S.account("2183")
    rows = Api.preview_schedule(S.reader, asset_input).value!
    rows.first.accounting.should eq(S.d("534.25"))
    rows.sum(BigDecimal.new(0), &.accounting).should eq(S.d("1800"))
    Api.preview_schedule(S.reader, asset_input(life_months: 0)).error_keys.should eq(["amortis.errors.asset.life_months.range"])
  end

  it "propose les acquisitions passées au débit d'un compte d'immobilisation, puis les rattache" do
    S.setup
    S.account("2183")
    lines = [Acc::EntryLineInput.new("2183", Acc::Side::Debit, S.d("2400"), label: "Serveur"),
             Acc::EntryLineInput.new("400", Acc::Side::Credit, S.d("2400"))]
    entry = Acc.post_entry(S.accountant, Acc::EntryInput.new(ledger_id: S.misc_ledger.id, date: S.date("2026-05-04"),
      lines: lines, label: "Achat serveur")).value!
    candidates = Api.candidates(S.accountant)
    candidates.map { |item| {item.account, item.amount, item.label} }.should eq([{"2183", S.d("2400"), "Serveur"}])
    Api.candidates(S.reader).should be_empty
    Api.candidate_count(S.accountant).should eq(1)
    line_id = candidates.first.line_id
    view = Api.create_asset(S.accountant, asset_input(label: "Serveur", gross: "2400", entry_line_id: line_id)).value!
    view.entry_id.should eq(entry.id)
    Api.candidates(S.accountant).should be_empty
    Api.candidate_count(S.accountant).should be_nil
    Api.check_asset(S.accountant, asset_input(entry_line_id: line_id)).error_keys.should eq(["amortis.errors.asset.entry_line.taken"])
    Api.check_asset(S.accountant, asset_input(entry_line_id: 999_999_i64)).error_keys.should eq(["amortis.errors.asset.entry_line.unknown"])
  end

  it "montre une tuile : immobilisations en service, valeur nette, acquisitions à inscrire" do
    S.setup
    S.asset("Ordinateur", "2183", "1800", "2026-02-10", months: 36)
    S.asset("Terrain", "211", "50000", "2026-02-10", method: "none")
    tile = present(Api.tile(S.accountant))
    tile.in_service_count.should eq(2)
    tile.net_value.should eq(S.d("51265.75"))
    tile.candidate_count.should eq(0)
  end
end
