# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Amortis::SpecSupport
private alias Api = Amortis::Api
private alias Acc = Partiduo::Api::Accounting

# Administrateur connecté (profil ADMIN : toutes les permissions), dossier
# provisionné l'extension active (comptes de l'inventaire créés),
# exercices 2025 à 2027.
private def signed_in : PartiduoUi::Browser
  S.activate
  browser = PartiduoUi::Books.admin
  PartiduoUi::Reference.fiscal_year(2025)
  PartiduoUi::Reference.fiscal_year(2027)
  S.user("bruno@example.com", "Bruno")
  browser
end

private def asset_form(label : String = "Ordinateur", account : String = "2183") : Hash(String, String)
  {"label" => label, "code" => "", "parent_id" => "", "card_code" => "", "notes" => "", "asset_account" => account,
   "depreciation_account" => "", "impairment_account" => "", "expense_account" => "", "acquired_on" => "2026-02-10",
   "in_service_on" => "2026-02-10", "gross_value" => "1800", "residual_value" => "0", "new_asset" => "1",
   "method" => "linear", "life_years" => "3", "fiscal_method" => "same", "fiscal_life_years" => "", "entry_line_id" => ""}
end

describe "Écrans des immobilisations sous /ext/AMORTIS/ (ADR-005)" do
  it "est montée sous le code de l'extension, avec ses permissions par route" do
    Marten.routes.reverse("amortis:assets").should eq("/ext/AMORTIS/assets")
    Marten.routes.reverse("amortis:asset", id: 4).should eq("/ext/AMORTIS/assets/4")
    mount = PartiduoUi::Extensions["AMORTIS"]? || raise("interface non montée")
    mount.permission.should eq("amortis.read")
    mount.permission_for("amortis:asset_new").should eq("amortis.write")
    mount.permission_for("amortis:postings_post").should eq("amortis.write")
    mount.permission_for("amortis:posting_cancel").should eq("amortis.write")
    mount.permission_for("amortis:statements").should eq("amortis.read")
    mount.permission_for("amortis:settings").should eq("amortis.admin")
  end

  it "n'existe pas tant que l'extension est inactive (404) et renvoie un anonyme vers la connexion" do
    browser = PartiduoUi::Books.admin
    browser.get("/ext/AMORTIS/assets").status.should eq(404)
    S.activate
    response = PartiduoUi::Browser.new.get("/ext/AMORTIS/assets")
    response.status.should eq(302)
    response.headers["Location"].should eq("/login?next=%2Fext%2FAMORTIS%2Fassets")
  end

  it "inscrit une immobilisation par le formulaire, avec l'aperçu du plan en HTMX, puis montre sa fiche" do
    browser = signed_in
    S.account("2183", "Matériel de bureau et informatique")
    browser.get("/ext/AMORTIS/").headers["Location"].should eq("/ext/AMORTIS/assets")
    form = browser.get("/ext/AMORTIS/assets/new").html
    form.should contain("<h1>Nouvelle immobilisation")
    form.should contain(%(hx-post="/ext/AMORTIS/assets/preview"))
    form.should contain("Plan fiscal")
    preview = browser.post("/ext/AMORTIS/assets/preview", asset_form)
    preview.status.should eq(200)
    preview.html.should contain(%(id="amo-preview-table"))
    preview.html.should contain("534,25")
    browser.post("/ext/AMORTIS/assets/preview", asset_form.merge({"life_years" => "0"})).html.should contain("data-amo-preview-errors")

    refused = browser.post("/ext/AMORTIS/assets/new", asset_form.merge({"label" => "", "gross_value" => "abc"}))
    refused.status.should eq(422)
    refused.html.should contain("aria-invalid=\"true\"")

    created = browser.post("/ext/AMORTIS/assets/new", asset_form)
    created.status.should eq(302)
    detail = browser.follow(created).html
    detail.should contain("Immobilisation IMM-00001 inscrite.")
    detail.should contain("Tableau d'amortissement")
    detail.should contain("28183")
    detail.should contain("534,25")
    detail.should contain("En service")
    view = Api.assets(S.system).first
    csv = browser.get("/ext/AMORTIS/assets/#{view.id}?format=csv")
    csv.content_type.should contain("text/csv")
    csv.content.should contain("534,25")
    list = browser.get("/ext/AMORTIS/assets").html
    list.should contain("IMM-00001")
    list.should contain("Matériel de bureau et informatique, mobilier")
  end

  it "propose les dotations de l'exercice, passe l'écriture d'inventaire et l'extourne" do
    browser = signed_in
    S.asset("Ordinateur", "2183", "1800", "2026-02-10", months: 36)
    year = S.fiscal_year(2026)
    page = browser.get("/ext/AMORTIS/postings?year=#{year.id}").html
    page.should contain("Dotations proposées 2026")
    page.should contain("data-amo-post")
    page.should contain("6811")
    posted = browser.post("/ext/AMORTIS/postings/post", {"year" => year.id.to_s, "ledger_id" => S.misc_ledger.id.to_s,
                                                         "date" => "2026-12-31"})
    posted.status.should eq(302)
    after = browser.follow(posted).html
    after.should contain("Écriture d'inventaire passée.")
    after.should contain("Aucune dotation à passer pour cet exercice.")
    posting = Api.postings(S.system).first
    cancelled = browser.post("/ext/AMORTIS/postings/#{posting.id}/cancel", {} of String => String)
    cancelled.status.should eq(302)
    browser.follow(cancelled).html.should contain("Écriture d'inventaire extournée.")
    Api.posting(S.system, posting.id).cancelled?.should be_true
  end

  it "enregistre une dépréciation et une cession depuis la fiche, puis passe l'écriture de sortie" do
    browser = signed_in
    view = S.asset("Ordinateur", "2183", "1800", "2026-02-10", months: 36)
    refused = browser.post("/ext/AMORTIS/assets/#{view.id}/impairments", {"date" => "2026-11-30", "amount" => "0", "label" => ""})
    refused.status.should eq(422)
    refused.html.should contain("Le montant de la dépréciation ne peut être nul.")
    browser.post("/ext/AMORTIS/assets/#{view.id}/impairments", {"date" => "2026-11-30", "amount" => "300", "label" => "Casse"})
      .status.should eq(302)
    impairment = Api.impairments(S.system, view.id).first
    browser.post("/ext/AMORTIS/impairments/#{impairment.id}/post", {} of String => String).status.should eq(302)
    Api.impairment(S.system, impairment.id).posted?.should be_true

    disposed = browser.post("/ext/AMORTIS/assets/#{view.id}/dispose", {"disposed_on" => "2026-12-15", "kind" => "sale",
                                                                       "price" => "900", "label" => ""})
    disposed.status.should eq(302)
    detail = browser.follow(disposed).html
    detail.should contain("data-amo-disposal")
    detail.should contain("Écriture de sortie proposée")
    detail.should contain("675")
    browser.post("/ext/AMORTIS/assets/#{view.id}/dispose/post", {} of String => String).status.should eq(302)
    present(Api.asset(S.system, view.id).disposal).posted?.should be_true
  end

  it "affiche les états de l'exercice, exportables, et le registre de la 2035" do
    browser = signed_in
    S.asset("Ordinateur", "2183", "1800", "2026-02-10", months: 36)
    year = S.fiscal_year(2026)
    page = browser.get("/ext/AMORTIS/statements?year=#{year.id}").html
    page.should contain("Immobilisations (2054)")
    page.should contain("Amortissements (2055)")
    page.should contain("Amortissements dérogatoires (2055, cadre B)")
    page.should contain("data-amo-unposted")
    csv = browser.get("/ext/AMORTIS/statements?year=#{year.id}&kind=statement&part=depreciation&format=csv")
    csv.content_type.should contain("text/csv")
    csv.content.should contain("534,25")
    register = browser.get("/ext/AMORTIS/statements?year=#{year.id}&kind=register").html
    register.should contain("Registre de la 2035")
    register.should contain("Ordinateur")
    browser.get("/ext/AMORTIS/coefficients").html.should contain("Loi de finances rectificative pour 2008")
  end

  it "règle l'extension et crée les comptes manquants" do
    browser = signed_in
    page = browser.get("/ext/AMORTIS/settings").html
    page.should contain("Journal des écritures d'inventaire")
    page.should contain("6811")
    refused = browser.post("/ext/AMORTIS/settings", {"ledger_id" => "", "day_count" => "actual", "expense_account" => "68119"})
    refused.status.should eq(422)
    refused.html.should contain("Le compte 68119 n'existe pas au plan comptable.")
    saved = browser.post("/ext/AMORTIS/settings", {"ledger_id" => S.misc_ledger.id.to_s, "day_count" => "360"})
    saved.status.should eq(302)
    Api.settings(S.system).day_count.should eq("360")
    accounts = browser.post("/ext/AMORTIS/settings/accounts", {} of String => String)
    browser.follow(accounts).html.should contain("Tous les comptes existent déjà.")
  end

  it "liste les acquisitions à inscrire et préremplit la saisie depuis l'une d'elles" do
    browser = signed_in
    S.account("2183")
    lines = [Acc::EntryLineInput.new("2183", Acc::Side::Debit, S.d("2400"), label: "Serveur"),
             Acc::EntryLineInput.new("400", Acc::Side::Credit, S.d("2400"))]
    Acc.post_entry(S.system, Acc::EntryInput.new(ledger_id: S.misc_ledger.id, date: S.date("2026-05-04"), lines: lines)).value!
    page = browser.get("/ext/AMORTIS/candidates").html
    page.should contain("Serveur")
    line_id = Api.candidates(S.system).first.line_id
    form = browser.get("/ext/AMORTIS/assets/new?line=#{line_id}").html
    form.should contain(%(name="entry_line_id" value="#{line_id}"))
    form.should contain(%(value="Serveur"))
    browser.get("/").html.should contain("Immobilisations en service")
  end
end
