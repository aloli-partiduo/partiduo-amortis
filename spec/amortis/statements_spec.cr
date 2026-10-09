# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Amortis::SpecSupport
private alias Api = Amortis::Api

private def portfolio : Nil
  S.setup
  S.asset("Presse", "2154", "10000", "2026-04-15", fiscal_method: "degressive", fiscal_months: 60)
  S.asset("Ordinateur", "2183", "1800", "2026-02-10", months: 36)
  truck = S.asset("Camion", "2182", "30000", "2025-01-01", fiscal_method: "linear", fiscal_months: 48)
  S.asset("Terrain", "211", "50000", "2025-03-01", method: "none")
  Api.dispose(S.accountant, truck.id, Api::DisposalInput.new(S.date("2026-06-30"), "sale", S.d("20000"))).value!
end

describe "États des immobilisations et des amortissements (D-AMO-013, D-AMO-014)" do
  it "dresse les tableaux 2054 et 2055 par rubrique : valeurs brutes, amortissements par mode, dérogatoires" do
    portfolio
    view = Api.statement(S.reader, S.fiscal_year(2026).id)
    view.regime.should eq("fr")
    view.rows.map(&.rubric).should eq(%w[land technical transport office])
    land, technical, transport, office = view.rows
    {land.gross_opening, land.gross_closing, land.depreciation_closing}.should eq({S.d("50000"), S.d("50000"), S.d("0")})
    {technical.gross_increase, technical.depreciation_charge, technical.charge_linear}.should eq({S.d("10000"), S.d("1430.14"), S.d("1430.14")})
    technical.derogatory_charge_degressive.should eq(S.d("1194.86"))
    {transport.gross_opening, transport.gross_decrease, transport.gross_closing}.should eq({S.d("30000"), S.d("30000"), S.d("0")})
    {transport.depreciation_opening, transport.depreciation_charge, transport.depreciation_decrease, transport.depreciation_closing}
      .should eq({S.d("6000"), S.d("2975.34"), S.d("8975.34"), S.d("0")})
    {transport.derogatory_opening, transport.derogatory_charge_duration, transport.derogatory_release_duration, transport.derogatory_closing}
      .should eq({S.d("1500"), S.d("743.84"), S.d("2243.84"), S.d("0")})
    office.depreciation_charge.should eq(S.d("534.25"))
    total = view.total
    {total.gross_opening, total.gross_increase, total.gross_decrease, total.gross_closing}
      .should eq({S.d("80000"), S.d("11800"), S.d("30000"), S.d("61800")})
    {total.depreciation_charge, total.depreciation_closing, total.net_closing}
      .should eq({S.d("4939.73"), S.d("1964.39"), S.d("59835.61")})
    view.unposted.should eq(S.d("1964.39"))

    previous = Api.statement(S.reader, S.fiscal_year(2025).id)
    previous.total.gross_increase.should eq(S.d("80000"))
    previous.total.depreciation_charge.should eq(S.d("6000"))
    previous.total.derogatory_charge_duration.should eq(S.d("1500"))
  end

  it "tient le registre de la 2035 sur le plan fiscal, avec les plus-values à court et à long terme" do
    portfolio
    view = Api.register(S.reader, S.fiscal_year(2026).id)
    view.rows.map(&.label).should eq(["Camion", "Terrain", "Ordinateur", "Presse"])
    truck = view.rows.first
    {truck.method, truck.rate, truck.prior, truck.charge, truck.net_value}
      .should eq({"linear", S.d("25"), S.d("7500"), S.d("3719.18"), S.d("18780.82")})
    {truck.disposed_on, truck.price, truck.short_term, truck.long_term}
      .should eq({S.date("2026-06-30"), S.d("20000"), S.d("1219.18"), S.d("0")})
    press = view.rows.last
    {press.method, press.rate, press.charge}.should eq({"degressive", S.d("35"), S.d("2625")})
    view.total_charge.should eq(S.d("6878.43"))
    view.total_short_term.should eq(S.d("1219.18"))
  end

  it "range les immobilisations belges dans les rubriques du PCMN" do
    S.setup("be")
    S.asset("Machine", "240", "12000", "2026-01-01")
    view = Api.statement(S.reader, S.fiscal_year(2026).id)
    view.regime.should eq("be")
    view.rows.map(&.rubric).should eq(["be_furniture_vehicles"])
    view.total.depreciation_charge.should eq(S.d("2400"))
  end
end
