# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Amortis::SpecSupport
private alias Api = Amortis::Api

private def menu_routes(entries : Array(Partiduo::Api::Modules::MenuView)) : Array(String?)
  entries.flat_map { |entry| [entry.route] + menu_routes(entry.children) }
end

describe "Extension AMORTIS : manifeste et activation (ADR-003 D2)" do
  it "déclare une extension conforme au contrat du cœur, qui dépend de la Comptabilité et refuse un foyer" do
    manifest = Partiduo::Modules[Amortis::CODE]
    manifest.kind.should eq(Partiduo::Modules::Kind::Extension)
    manifest.version.should eq(Amortis::VERSION)
    Amortis::VERSION.should match(/\A\d+\.\d+\.\d+\z/)
    manifest.requires_core.should eq("~> 0.1")
    manifest.permissions.should eq(["amortis.read", "amortis.write", "amortis.admin"])
    manifest.depends_on.should eq(["ACCOUNTING"])
    manifest.incompatible_with.should be_empty
    manifest.incompatible_with_kind.should eq(["household"])
    Partiduo::Api::InitialData.excluded_modules("household").should contain(Amortis::CODE)
    manifest.subscribed_events.should eq(["entry.cancelled"])
    manifest.uis.map(&.path).should eq(["ui/bulma"])
    manifest.menus.map { |menu| {menu.code, menu.parent, menu.route} }.should eq([
      {"AMORTIS", nil, nil},
      {"AMORTIS_ASSETS", "AMORTIS", "amortis:assets"},
      {"AMORTIS_POSTINGS", "AMORTIS", "amortis:postings"},
      {"AMORTIS_STATEMENTS", "AMORTIS", "amortis:statements"},
      {"AMORTIS_SETTINGS", "SETTINGS", "amortis:settings"},
    ])
    Partiduo::Modules.structure_errors.should be_empty
    Partiduo::Modules.dependency_errors(manifest, Set{Amortis::CODE, "ACCOUNTING"}).should be_empty
    Partiduo::Modules.dependency_errors(manifest, Set{Amortis::CODE}).should eq(["AMORTIS requiert ACCOUNTING, inactif"])
  end

  it "traduit son nom, ses permissions et ses menus dans chaque langue de l'interface" do
    manifest = Partiduo::Modules[Amortis::CODE]
    keys = [manifest.name] + manifest.permission_entries.map(&.label) + manifest.menus.map(&.label)
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) do
        keys.each { |key| I18n.t(key).should_not contain("missing") }
      end
    end
    I18n.with_locale("fr") { I18n.t("amortis.menu.amortis").should eq("Immobilisations") }
  end

  it "est inactive tant que l'instance ne l'active pas, puis se montre au menu « Immobilisations »" do
    PartiduoUi::Reference.provision
    S.user("alice@example.com", "Alice")
    S.user("bruno@example.com", "Bruno")
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.assets(S.reader) }
    Api.tile(S.reader).should be_nil
    Api.candidate_count(S.reader).should be_nil
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should_not contain("amortis:assets")

    S.activate
    Partiduo::Modules.check!
    section = Partiduo::Api::Modules.menu(S.reader).find! { |item| item.code == "AMORTIS" }
    section.label_key.should eq("amortis.menu.amortis")
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should contain("amortis:assets")
    menu_routes(Partiduo::Api::Modules.menu(S.reader)).should_not contain("amortis:settings")
    menu_routes(Partiduo::Api::Modules.menu(S.accountant)).should contain("amortis:settings")
    expect_raises(Partiduo::Api::Forbidden) { Api.create_asset(S.reader, Api::AssetInput.new("X", "2183", Time.utc, BigDecimal.new(1))) }
  end

  it "crée les comptes de l'inventaire au provisionnement d'un dossier d'entreprise, et sur demande" do
    S.setup
    %w[6811 6816 7816 6872 7872 675 775 462].each { |number| Amortis::Accounts.exists?(number).should be_true }
    Partiduo::Api::Accounting.account(S.system, "462").kind.should eq(Partiduo::Api::Accounting::AccountKind::Asset)
    Api.ensure_accounts(S.accountant).value!.should be_empty
    Api.update_settings(S.accountant, Api::SettingsInput.new(expense_account: "68112")).error_keys
      .should eq(["amortis.errors.account.missing"])
  end

  it "est exclue du dossier d'un foyer par le cœur : activation et démarrage refusés (D-AMO-020)" do
    S.setup
    Api.assets(S.reader).should be_empty
    Marten::DB::Connection.default.open(&.exec("UPDATE core_settings SET kind = 'household'"))
    # Dossier foyer où l'extension était déjà active : le démarrage la nomme.
    Partiduo::Modules.kind_errors(Partiduo::Modules::State.active_codes, "household")
      .should contain("AMORTIS est exclu des dossiers de type household, actif")
    expect_raises(Partiduo::Modules::ConfigurationError, /AMORTIS est exclu/) { Partiduo::Modules.check! }
    Partiduo::Api::Modules.deactivate(S.system, Amortis::CODE).value!
    Partiduo::Api::Modules.activate(S.system, Amortis::CODE).error_keys
      .should eq(["modules.errors.activation.excluded_kind"])
    Partiduo::Modules.kind_errors(Partiduo::Modules::State.active_codes, "household").join("\n")
      .should_not contain("AMORTIS")
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.assets(S.reader) }
    Api.tile(S.accountant).should be_nil
  end

  it "range ses tables sous le préfixe amortis_ et refuse en base les valeurs hors domaine" do
    [Amortis::Asset, Amortis::Disposal, Amortis::Impairment, Amortis::Posting, Amortis::PostingLine, Amortis::Setting]
      .map(&.db_table).should eq(%w[amortis_asset amortis_disposal amortis_impairment amortis_posting amortis_posting_line
      amortis_setting])
    S.setup
    view = S.asset("Camion", "2182", "30000", "2026-03-01")
    sql_error = ->(sql : String) do
      Marten::DB::Connection.default.open(&.exec(sql))
      nil
  rescue ex : PQ::PQError
    ex.message
    end
    sql_error.call("UPDATE amortis_asset SET method = 'sum_of_years' WHERE id = #{view.id}").to_s.should contain("amortis_asset_method_check")
    sql_error.call("UPDATE amortis_asset SET residual_value = 30000 WHERE id = #{view.id}").to_s.should contain("amortis_asset_residual_check")
    sql_error.call("UPDATE amortis_asset SET in_service_on = '2025-01-01' WHERE id = #{view.id}").to_s.should contain("amortis_asset_service_check")
    sql_error.call("UPDATE amortis_asset SET life_months = 0 WHERE id = #{view.id}").to_s.should contain("amortis_asset_life_check")
    sql_error.call("INSERT INTO amortis_disposal (asset_id, disposed_on, kind, price, label, created_at, updated_at) " \
                   "VALUES (#{view.id}, '2026-06-01', 'scrap', 10, '', now(), now())").to_s.should contain("amortis_disposal_price_check")
    sql_error.call("INSERT INTO amortis_impairment (asset_id, date, amount, label, created_at, updated_at) " \
                   "VALUES (#{view.id}, '2026-06-01', 0, '', now(), now())").to_s.should contain("amortis_impairment_amount_check")
  end
end
