# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Amortis::SpecSupport
private alias Api = Amortis::Api
private alias Liberal = Partiduo::Api::Liberal

private def portfolio : Nil
  S.setup
  S.asset("Presse", "2154", "10000", "2026-04-15", fiscal_method: "degressive", fiscal_months: 60)
  S.asset("Ordinateur", "2183", "1800", "2026-02-10", months: 36)
  truck = S.asset("Camion", "2182", "30000", "2025-01-01", fiscal_method: "linear", fiscal_months: 48)
  S.asset("Terrain", "211", "50000", "2025-03-01", method: "none")
  Api.dispose(S.accountant, truck.id, Api::DisposalInput.new(S.date("2026-06-30"), "sale", S.d("20000"))).value!
end

private def zones(pairs : Hash(String, Int32)) : Hash(String, BigDecimal)
  pairs.transform_values { |value| BigDecimal.new(value) }
end

describe "Annexes 2054 et 2055 de la liasse, fournies à TELEDEC (A-AMO-2, D-AMO-017)" do
  it "traduit les rubriques de l'état de l'exercice en zones de TELEDEC, arrondies à l'euro" do
    portfolio
    boxes = present(Api.liasse_annexes(S.reader, S.fiscal_year(2026).id))
    boxes["2054"].should eq(zones({
      "KG" => 50000, "LY" => 50000,                               # terrains
      "KU" => 10000, "MK" => 10000,                               # installations techniques
      "KY" => 30000, "MP" => 30000,                               # matériel de transport, cédé
      "LD" => 1800, "MT" => 1800,                                 # matériel de bureau
      "LN" => 80000, "LP" => 11800, "NG" => 30000, "NH" => 61800, # total III
      "PN" => 80000, "PQ" => 11800, "RK" => 30000, "RL" => 61800, # total général
    }))
    boxes["2055"].should eq(zones({
      "QA" => 1430, "QC" => 1430,                             # installations techniques
      "QH" => 6000, "QI" => 2975, "QJ" => 8975,               # transport (sorti)
      "QM" => 534, "QO" => 534,                               # bureau
      "QU" => 6000, "QV" => 4939, "QW" => 8975, "QX" => 1964, # total II
      "TA" => 6000, "TB" => 4939, "TC" => 8975, "TD" => 1964, # total général
      "CG" => 1195, "HG" => 1195,                             # dérogatoire, mode dégressif
      "BJ" => 744, "EJ" => 2244, "HJ" => -1500,               # dérogatoire, durée, repris à la sortie
      "BM" => 744, "CM" => 1195, "EM" => 2244, "HM" => -305,
      "BN" => 744, "CN" => 1195, "EN" => 2244, "HN" => -305,
    }))
    # Toutes les zones sont connues de TELEDEC au millésime de la liasse.
    target = Teledec::Remote::Millesime.target("liasse", "2026-12-31")
    text = boxes.transform_values(&.transform_values(&.to_s))
    Teledec::Remote::Formats.unknown_zones(text, target).should be_empty
    Amortis::Annexes.rank(S.date("2026-12-31")).should eq(202701)
  end

  it "ne fournit rien hors de France ni sans immobilisation" do
    S.setup
    Api.liasse_annexes(S.reader, S.fiscal_year(2026).id).should be_nil
  end

  it "s'enregistre auprès de TELEDEC : la liasse du réel normal joint ses annexes" do
    Teledec::Api.annex_providers.map { |item| {item.code, item.forms} }.should eq([{"AMORTIS", %w[2054 2055]}])
    portfolio
    Partiduo::Api::Modules.activate(S.system, Teledec::CODE).value!
    Teledec::Api.update_settings(S.system, Teledec::Api::SettingsInput.new("is_rn", "none", false)).value!
    input = Teledec::Api::PrepareInput.new(kind: "liasse", fiscal_year_id: S.fiscal_year(2026).id)
    filing = Teledec::Api.prepare(S.system, input).value!
    filing.forms.should eq(%w[2065 2050])
    filing.details["annexes"].should eq("AMORTIS:2054+2055")
    joined = filing.boxes.select(&.form.==("2054")).to_h { |box| {box.box, box.amount} }
    joined["MT"].should eq(BigDecimal.new(1800))
    filing.controls.map(&.key).select(&.starts_with?("teledec.controls.annex")).should be_empty

    # Extension inactive : TELEDEC ne la consulte plus.
    Partiduo::Api::Modules.deactivate(S.system, Amortis::CODE).value!
    again = Teledec::Api.prepare(S.system, input).value!
    again.boxes.should be_empty
    again.details.has_key?("annexes").should be_false
  end
end

describe "Immobilisations de la 2035 fournies au module liberal (A-AMO-3, D-AMO-018)" do
  it "remplace le registre linéaire du module par le registre fiscal de l'extension" do
    portfolio
    source = present(Api.liberal_assets(S.reader, 2026))
    source.label_key.should eq("amortis.module.name")
    source.rows.map { |row| {row.label, row.category, row.year_amount} }.should eq([
      {"Camion", "vehicle", S.d("3719.18")}, {"Terrain", "land", S.d("0")},
      {"Ordinateur", "office", S.d("534.25")}, {"Presse", "equipment", S.d("2625")},
    ])
    truck = source.disposals.first
    {truck.label, truck.price, truck.net_value, truck.short_term, truck.long_term}
      .should eq({"Camion", S.d("20000"), S.d("18780.82"), S.d("1219.18"), S.d("0")})
    Api.liberal_assets(S.reader, 2030).should be_nil

    Partiduo::Api::Modules.activate(S.system, "LIBERAL").value!
    Liberal.load_defaults(S.system)
    prepared = Liberal.tax_return(S.system, 2026)
    prepared.asset_source.should eq(Amortis::CODE)
    prepared.assets.map(&.label).should eq(["Camion", "Terrain", "Ordinateur", "Presse"])
    prepared.disposals.map(&.label).should eq(["Camion"])

    # Extension inactive : la 2035 reprend le registre du module.
    Partiduo::Api::Modules.deactivate(S.system, Amortis::CODE).value!
    Liberal.tax_return(S.system, 2026).asset_source.should eq("")
  end
end
