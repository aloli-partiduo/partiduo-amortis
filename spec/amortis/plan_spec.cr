# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias Plan = Amortis::Plan

private def d(text : String) : BigDecimal
  BigDecimal.new(text)
end

private def day(text : String) : Time
  Time.parse_utc(text, "%Y-%m-%d")
end

private def calendar_years(from : Int32, to : Int32) : Array(Amortis::Exercise)
  (from..to).map { |year| Amortis::Exercise.new(day("#{year}-01-01"), day("#{year}-12-31"), year.to_i64, year.to_s) }
end

private def plan(input : Plan::Input, exercises = calendar_years(2026, 2026)) : Array(Plan::Row)
  from, to = Plan.horizon(input)
  Plan.rows(input, Amortis::Calendar.exercises(exercises, from, to))
end

private def input(gross : String = "10000", acquired : String = "2026-04-15", method : String = "linear", months : Int32 = 60,
                  regime : String = "fr", day_count : String = "actual", fiscal_method : String = "same",
                  fiscal_months : Int32? = nil, impairments = [] of {Time, BigDecimal}, disposed : String? = nil,
                  residual : String = "0", service : String? = nil) : Plan::Input
  Plan::Input.new(regime: regime, day_count: day_count, acquired_on: day(acquired), in_service_on: day(service || acquired),
    gross: d(gross), residual: d(residual), method: method, life_months: months, fiscal_method: fiscal_method,
    fiscal_life_months: fiscal_months, impairments: impairments, disposed_on: disposed.try { |text| day(text) })
end

private def charges(rows : Array(Plan::Row)) : Array({String, String})
  rows.map { |row| {row.exercise.display_label, row.accounting.to_s} }
end

describe "Plans d'amortissement (D-AMO-005, D-AMO-006)" do
  it "amortit en linéaire au prorata temporis des jours réels, la dernière dotation soldant le plan" do
    rows = plan(input)
    charges(rows).should eq([{"2026", "1430.14"}, {"2027", "2000.0"}, {"2028", "2000.0"}, {"2029", "2000.0"},
                             {"2030", "2000.0"}, {"2031", "569.86"}])
    rows.last.accounting_cumul.should eq(d("10000"))
    rows.last.net_value.should eq(d("0"))
  end

  it "compte les jours en année commerciale de 360 jours si le dossier le demande" do
    charges(plan(input(day_count: "360"))).first(2).should eq([{"2026", "1422.22"}, {"2027", "2000.0"}])
  end

  it "amortit la base diminuée de la valeur résiduelle" do
    rows = plan(input(residual: "1000"))
    rows.sum(BigDecimal.new(0), &.accounting).should eq(d("9000"))
    rows.last.net_value.should eq(d("1000"))
  end

  it "rapporte la dotation à la durée d'un exercice qui ne fait pas douze mois" do
    exercises = [Amortis::Exercise.new(day("2026-01-01"), day("2027-06-30"), 1_i64, "2026-2027")]
    rows = plan(input(acquired: "2026-01-01"), exercises)
    rows.first.accounting.should eq(d("3000"))
    rows[1].exercise.starts_on.should eq(day("2027-07-01"))
    rows[1].accounting.should eq(d("2000"))
  end

  it "applique le dégressif français du mois d'acquisition, au coefficient de la date, et bascule au linéaire" do
    rows = plan(input(method: "degressive"))
    rows.map { |row| {row.accounting.to_s, row.accounting_mode} }.should eq([
      {"2625.0", "degressive"}, {"2581.25", "degressive"}, {"1677.81", "degressive"}, {"1384.86", "linear"},
      {"1384.86", "linear"}, {"346.22", "linear"},
    ])
    rows.sum(BigDecimal.new(0), &.accounting).should eq(d("10000"))
  end

  it "date les coefficients du dégressif : 1,75 / 2,25 / 2,75 entre décembre 2008 et 2009, 1,25 / 1,75 / 2,25 sinon" do
    Amortis::Coefficients.fr(day("2009-06-01"), 60).should eq(d("2.25"))
    Amortis::Coefficients.fr(day("2009-06-01"), 36).should eq(d("1.75"))
    Amortis::Coefficients.fr(day("2026-06-01"), 48).should eq(d("1.25"))
    Amortis::Coefficients.fr(day("2026-06-01"), 72).should eq(d("1.75"))
    Amortis::Coefficients.fr(day("2026-06-01"), 120).should eq(d("2.25"))
    Amortis::Coefficients.fr(day("2000-06-01"), 120).should eq(d("2.5"))
    Amortis::Coefficients.fr(day("2026-06-01"), 24).should be_nil
  end

  it "tire l'amortissement dérogatoire de l'écart entre plan fiscal et plan comptable, soldé en fin de plan" do
    rows = plan(input(fiscal_method: "degressive", fiscal_months: 60))
    rows.map(&.derogatory.to_s).should eq(["1194.86", "581.25", "-322.19", "-615.14", "-615.14", "-223.64"])
    rows.last.derogatory_cumul.should eq(d("0"))
    plan(input(fiscal_method: "linear", fiscal_months: 36)).first.derogatory.should eq(d("953.42"))
  end

  it "repart de la valeur nette après une dépréciation, sur la durée restante" do
    rows = plan(input(impairments: [{day("2027-06-30"), d("1000")}]))
    rows[1].impairment.should eq(d("1000"))
    rows[2].accounting.should eq(d("1695.58"))
    rows.last.net_value.should eq(d("0"))
    (rows.last.accounting_cumul + rows.last.impairment_cumul).should eq(d("10000"))
  end

  it "arrête le plan à la cession, au jour près, et calcule les plus-values à court et à long terme" do
    sale = input(disposed: "2028-03-31")
    rows = plan(sale)
    rows.last.disposed.should be_true
    rows.last.accounting.should eq(d("497.27"))
    result = Plan.disposal(sale, rows, d("7000"))
    result.net_value.should eq(d("6072.59"))
    result.result.should eq(d("927.41"))
    {result.short_term, result.long_term}.should eq({d("927.41"), d("0")})
    later = input(disposed: "2028-06-30")
    profit = Plan.disposal(later, plan(later), d("12000"))
    profit.accounting_cumul.should eq(d("4424.68"))
    {profit.short_term, profit.long_term}.should eq({d("4424.68"), d("2000")})
  end

  it "applique le dégressif belge : double du linéaire plafonné à 40 %, prorata au jour, bascule au linéaire" do
    rows = plan(input(regime: "be", acquired: "2019-04-15", method: "degressive"), calendar_years(2019, 2019))
    charges(rows).should eq([{"2019", "2860.27"}, {"2020", "2855.89"}, {"2021", "2000.0"}, {"2022", "2000.0"},
                             {"2023", "283.84"}])
    Amortis::Coefficients.be_rate(36).should eq(d("0.4"))
  end

  it "n'amortit ni un bien non amortissable ni un bien pas encore en service" do
    plan(input(method: "none")).should be_empty
    land = Plan::Input.new(regime: "fr", day_count: "actual", acquired_on: day("2026-01-01"), in_service_on: nil,
      gross: d("5000"), residual: d("0"), method: "linear", life_months: 60)
    plan(land).should be_empty
  end
end
