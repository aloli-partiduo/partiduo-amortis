# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Amortis::SpecSupport
private alias Api = Amortis::Api
private alias Acc = Partiduo::Api::Accounting

describe "Écritures d'inventaire par le contrat de la Comptabilité (D-AMO-009)" do
  it "propose les dotations de l'exercice sans rien passer, puis passe une écriture d'inventaire à la clôture" do
    S.setup
    press = S.asset("Presse", "2154", "10000", "2026-04-15", fiscal_method: "degressive", fiscal_months: 60)
    S.asset("Ordinateur", "2183", "1800", "2026-02-10", months: 36)
    year = S.fiscal_year(2026)
    proposal = Api.proposal(S.reader, year.id)
    proposal.lines.map { |line| {line.code, line.depreciation.to_s, line.derogatory.to_s} }
      .should eq([{"IMM-00001", "1430.14", "1194.86"}, {"IMM-00002", "534.25", "0.0"}])
    proposal.entry_lines.map { |line| {line.account, line.side.code, line.amount.to_s} }.should eq([
      {"6811", "debit", "1964.39"}, {"28154", "credit", "1430.14"}, {"28183", "credit", "534.25"},
      {"6872", "debit", "1194.86"}, {"145", "credit", "1194.86"},
    ])
    proposal.ledger_id.should eq(S.misc_ledger.id)
    proposal.date.should eq(S.date("2026-12-31"))
    proposal.blockers.should be_empty
    Acc.entries(S.accountant, Acc::EntryQuery.new(ledger_id: S.misc_ledger.id)).should be_empty

    posting = Api.post_depreciation(S.accountant, year.id).value!
    posting.kind.should eq("depreciation")
    posting.asset_count.should eq(2)
    posting.amount.should eq(S.d("3159.25"))
    entry = Acc.entry(S.accountant, posting.entry_id)
    {entry.ledger_code, entry.date, entry.source}.should eq({"O01", S.date("2026-12-31"), "amortis:depreciation:2026-01-01"})
    S.lines(posting.entry_id).should eq([{"145", "credit", "1194.86"}, {"28154", "credit", "1430.14"},
                                         {"28183", "credit", "534.25"}, {"6811", "debit", "1964.39"},
                                         {"6872", "debit", "1194.86"}])
    Api.proposal(S.reader, year.id).empty?.should be_true
    Api.post_depreciation(S.accountant, year.id).error_keys.should eq(["amortis.errors.posting.nothing"])
    Api.schedule(S.reader, press.id).rows.first.posted?.should be_true
  end

  it "fige le plan d'une immobilisation dont une écriture est passée, et le libère à l'extourne" do
    S.setup
    view = S.asset("Ordinateur", "2183", "1800", "2026-02-10", months: 36)
    year = S.fiscal_year(2026)
    posting = Api.post_depreciation(S.accountant, year.id).value!
    Api.asset(S.reader, view.id).locked.should be_true
    input = Api::AssetInput.new(label: "Ordinateur portable", asset_account: "2183", acquired_on: S.date("2026-02-10"),
      gross_value: S.d("1800"), code: view.code, in_service_on: S.date("2026-02-10"), life_months: 36)
    Api.update_asset(S.accountant, view.id, input).value!.label.should eq("Ordinateur portable")
    Api.update_asset(S.accountant, view.id, input.copy_with(gross_value: S.d("2000"))).error_keys
      .should eq(["amortis.errors.asset.locked"])
    Api.delete_asset(S.accountant, view.id).error_keys.should eq(["amortis.errors.asset.in_use"])

    cancelled = Api.cancel_posting(S.accountant, posting.id).value!
    cancelled.cancelled?.should be_true
    present(cancelled.reversal_entry_id).should_not eq(posting.entry_id)
    Acc.entry(S.accountant, posting.entry_id).cancelled?.should be_true
    Api.asset(S.reader, view.id).locked.should be_false
    Api.proposal(S.reader, year.id).total_depreciation.should eq(S.d("534.25"))
    Api.update_asset(S.accountant, view.id, input.copy_with(gross_value: S.d("2000"))).success?.should be_true
    Api.cancel_posting(S.accountant, posting.id).error_keys.should eq(["amortis.errors.posting.cancelled"])
  end

  it "suit une extourne faite dans la Comptabilité (entry.cancelled)" do
    S.setup
    S.asset("Ordinateur", "2183", "1800", "2026-02-10", months: 36)
    posting = Api.post_depreciation(S.accountant, S.fiscal_year(2026).id).value!
    Acc.cancel_entry(S.accountant, Acc::CancelEntryInput.new(posting.entry_id)).success?.should be_true
    Api.posting(S.reader, posting.id).status.should eq("cancelled")
    Api.proposal(S.reader, S.fiscal_year(2026).id).lines.size.should eq(1)
  end

  it "refuse une date hors de l'exercice et signale les comptes absents" do
    S.setup
    S.asset("Ordinateur", "2183", "1800", "2026-02-10", months: 36)
    year = S.fiscal_year(2026)
    Api.post_depreciation(S.accountant, year.id, Api::PostInput.new(date: S.date("2027-01-15"))).error_keys
      .should eq(["amortis.errors.posting.date.outside"])
    Api.update_settings(S.accountant, Api::SettingsInput.new(expense_account: "6811")).success?.should be_true
    Marten::DB::Connection.default.open(&.exec("UPDATE amortis_setting SET expense_account = '68119'"))
    Api.proposal(S.reader, year.id).blockers.map(&.key).should eq(["amortis.errors.account.missing"])
    Api.post_depreciation(S.accountant, year.id).error_keys.should eq(["amortis.errors.account.missing"])
    Api.post_depreciation(S.accountant, year.id, Api::PostInput.new(ledger_id: Acc.ledger_by_code(S.system, "F01").id))
      .error_keys.should contain("amortis.errors.ledger.invalid")
  end

  it "passe une dépréciation puis sa reprise, et refait le plan sur la valeur nette" do
    S.setup
    view = S.asset("Ordinateur", "2183", "1800", "2026-02-10", months: 36)
    impairment = Api.add_impairment(S.accountant, view.id, Api::ImpairmentInput.new(S.date("2026-11-30"), S.d("300"))).value!
    Api.add_impairment(S.accountant, view.id, Api::ImpairmentInput.new(S.date("2026-11-30"), S.d("-500"))).error_keys
      .should eq(["amortis.errors.impairment.amount.release_too_large"])
    Api.add_impairment(S.accountant, view.id, Api::ImpairmentInput.new(S.date("2026-11-30"), S.d("5000"))).error_keys
      .should eq(["amortis.errors.impairment.amount.too_large"])
    Api.proposal(S.reader, S.fiscal_year(2026).id).impairments.map(&.id).should eq([impairment.id])
    posting = Api.post_impairment(S.accountant, impairment.id).value!
    S.lines(posting.entry_id).should eq([{"29183", "credit", "300.0"}, {"6816", "debit", "300.0"}])
    Api.post_impairment(S.accountant, impairment.id).error_keys.should eq(["amortis.errors.impairment.posted"])
    Api.delete_impairment(S.accountant, impairment.id).error_keys.should eq(["amortis.errors.impairment.in_use"])
    rows = Api.schedule(S.reader, view.id).rows
    rows[1].accounting.should eq(S.d("457.79"))
    (rows.last.accounting_cumul + rows.last.impairment_cumul).should eq(S.d("1800"))

    release = Api.add_impairment(S.accountant, view.id, Api::ImpairmentInput.new(S.date("2027-06-30"), S.d("-100"))).value!
    S.lines(Api.post_impairment(S.accountant, release.id).value!.entry_id)
      .should eq([{"29183", "debit", "100.0"}, {"7816", "credit", "100.0"}])
  end

  it "sort un actif cédé : dotation complémentaire, dérogatoires repris, 675, 775 et 462, moins-value" do
    S.setup
    truck = S.asset("Camion", "2182", "30000", "2025-01-01", fiscal_method: "linear", fiscal_months: 48)
    Api.post_depreciation(S.accountant, S.fiscal_year(2025).id).value!
    Api.dispose(S.accountant, truck.id, Api::DisposalInput.new(S.date("2024-06-30"))).error_keys
      .should contain("amortis.errors.disposal.date.before_acquisition")
    Api.dispose(S.accountant, truck.id, Api::DisposalInput.new(S.date("2026-06-30"), "scrap", S.d("10"))).error_keys
      .should eq(["amortis.errors.disposal.price.scrap"])
    view = Api.dispose(S.accountant, truck.id, Api::DisposalInput.new(S.date("2026-06-30"), "sale", S.d("20000"))).value!
    disposal = present(view.disposal)
    disposal.result.should eq(S.d("-1024.66"))
    {disposal.short_term, disposal.long_term}.should eq({S.d("1219.18"), S.d("0")})
    view.status.should eq("disposed")
    Api.proposal(S.reader, S.fiscal_year(2026).id).tap do |proposal|
      proposal.lines.should be_empty
      proposal.disposals.map(&.id).should eq([truck.id])
    end
    Api.disposal_entry(S.reader, truck.id).map { |line| {line.account, line.side.code, line.amount.to_s} }.should eq([
      {"6811", "debit", "2975.34"}, {"28182", "credit", "2975.34"}, {"6872", "debit", "743.84"}, {"145", "credit", "743.84"},
      {"145", "debit", "2243.84"}, {"7872", "credit", "2243.84"}, {"28182", "debit", "8975.34"}, {"2182", "credit", "30000.0"},
      {"675", "debit", "21024.66"}, {"462", "debit", "20000.0"}, {"775", "credit", "20000.0"},
    ])
    posting = Api.post_disposal(S.accountant, truck.id).value!
    posting.kind.should eq("disposal")
    Acc.entry(S.accountant, posting.entry_id).date.should eq(S.date("2026-06-30"))
    Api.post_disposal(S.accountant, truck.id).error_keys.should eq(["amortis.errors.disposal.posted"])
    Api.cancel_disposal(S.accountant, truck.id).error_keys.should eq(["amortis.errors.disposal.posted"])
    Api.cancel_posting(S.accountant, posting.id).success?.should be_true
    Api.cancel_disposal(S.accountant, truck.id).value!.status.should eq("in_service")
  end

  it "sort une structure avec ses composants, et refuse une sortie antérieure à des dotations passées" do
    S.setup
    building = S.asset("Atelier", "213", "200000", "2025-01-01", months: 480)
    S.asset("Couverture", "213", "40000", "2025-01-01", months: 240, parent_id: building.id)
    Api.post_depreciation(S.accountant, S.fiscal_year(2026).id).value!
    Api.dispose(S.accountant, building.id, Api::DisposalInput.new(S.date("2025-12-31"), "scrap")).error_keys
      .should eq(["amortis.errors.disposal.date.later_posted"])
    Api.dispose(S.accountant, building.id, Api::DisposalInput.new(S.date("2026-12-31"), "scrap")).success?.should be_true
    component = Api.components(S.reader, building.id).first
    present(component.disposal).parent_disposal_id.should_not be_nil
    Api.post_disposal(S.accountant, component.id).error_keys.should eq(["amortis.errors.disposal.part_of_group"])
    lines = Api.disposal_entry(S.reader, building.id)
    lines.select(&.account.==("213")).map(&.amount).should eq([S.d("240000")])
    Api.post_disposal(S.accountant, building.id).success?.should be_true
  end

  it "applique le plan belge : sortie en plus-value nette (763), pas de dérogatoire, dégressif réservé" do
    S.setup("be")
    machine = S.asset("Machine", "240", "12000", "2026-01-01")
    machine.depreciation_account.should eq("2409")
    machine.expense_account.should eq("630")
    Api.check_asset(S.accountant, Api::AssetInput.new(label: "Presse", asset_account: "240", acquired_on: S.date("2026-01-01"),
      gross_value: S.d("1000"), in_service_on: S.date("2026-01-01"), method: "degressive", life_months: 60)).error_keys
      .should eq(["amortis.errors.degressive.be_abolished"])
    Api.check_asset(S.accountant, Api::AssetInput.new(label: "Presse", asset_account: "240", acquired_on: S.date("2026-01-01"),
      gross_value: S.d("1000"), life_months: 60, fiscal_method: "linear", fiscal_life_months: 36)).error_keys
      .should eq(["amortis.errors.asset.fiscal_method.be"])
    Api.update_settings(S.accountant, Api::SettingsInput.new(be_individual: true)).success?.should be_true
    S.asset("Presse", "240", "1000", "2026-01-01", method: "degressive").method.should eq("degressive")
    Api.dispose(S.accountant, machine.id, Api::DisposalInput.new(S.date("2026-12-31"), "sale", S.d("10000"))).value!
    Api.disposal_entry(S.reader, machine.id).map { |line| {line.account, line.side.code, line.amount.to_s} }.should eq([
      {"630", "debit", "2400.0"}, {"2409", "credit", "2400.0"}, {"2409", "debit", "2400.0"}, {"240", "credit", "12000.0"},
      {"416", "debit", "10000.0"}, {"763", "credit", "400.0"},
    ])
    posting = Api.post_disposal(S.accountant, machine.id).value!
    S.lines(posting.entry_id).should contain({"763", "credit", "400.0"})
  end
end
