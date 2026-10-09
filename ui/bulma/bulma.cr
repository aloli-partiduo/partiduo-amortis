# SPDX-License-Identifier: AGPL-3.0-or-later

# Interface Bulma de l'extension des immobilisations et des amortissements
# (ADR-005 D4) : registre (liste, fiche, saisie avec aperçu du plan en
# HTMX), composants, dépréciations, sorties, écritures d'inventaire
# proposées puis passées, états (2054, 2055, registre de la 2035, état
# belge), acquisitions à inscrire, réglages. Montée par `partiduo-ui-bulma`
# sous `/ext/AMORTIS/` (ADR-003 D3). La distribution la requiert après
# l'interface :
#
# ```
# require "partiduo-ui-bulma/partiduo_ui"
# require "partiduo-amortis"
# require "partiduo-amortis/ui/bulma"
# ```
#
# puis ajoute `Amortis::Ui::INSTALLED_APPS` à ses applications Marten.
#
# Ce dossier ne parle au métier que par `Amortis::Api` et `Partiduo::Api`
# (vérifié par `spec/architecture/conventions_spec.cr`) ; le contrôle
# d'accès est fait par l'interface, avant le handler, à partir du montage,
# puis par le contrat.
require "../../src/partiduo-amortis"

require "./presenters"
require "./handlers/base"
require "./handlers/**"
require "./dashboard_tile"

module Amortis
  module Ui
    # Application Marten de l'interface Bulma de l'extension : gabarits
    # (`templates/amortis/`), fichiers statiques (`assets/amortis/`) et
    # libellés d'écran (`locales/`, clés `amortis_ui.*`).
    class App < Marten::App
      label "amortis_ui"
    end

    INSTALLED_APPS = [Amortis::Ui::App] of Marten::Apps::Config.class

    # Routes servies sous `/ext/AMORTIS/`, nommées `amortis:<nom>` : celles
    # que citent les menus du manifeste.
    ROUTES = Marten::Routing::Map.draw do
      path "/", Amortis::Ui::IndexHandler, name: "index"
      path "/assets", Amortis::Ui::AssetsHandler, name: "assets"
      path "/assets/new", Amortis::Ui::AssetNewHandler, name: "asset_new"
      path "/assets/preview", Amortis::Ui::AssetPreviewHandler, name: "asset_preview"
      path "/assets/<id:int>", Amortis::Ui::AssetDetailHandler, name: "asset"
      path "/assets/<id:int>/edit", Amortis::Ui::AssetEditHandler, name: "asset_edit"
      path "/assets/<id:int>/delete", Amortis::Ui::AssetDeleteHandler, name: "asset_delete"
      path "/assets/<id:int>/impairments", Amortis::Ui::ImpairmentAddHandler, name: "impairment_add"
      path "/assets/<id:int>/dispose", Amortis::Ui::DisposeHandler, name: "dispose"
      path "/assets/<id:int>/dispose/cancel", Amortis::Ui::DisposeCancelHandler, name: "dispose_cancel"
      path "/assets/<id:int>/dispose/post", Amortis::Ui::DisposePostHandler, name: "dispose_post"
      path "/impairments/<id:int>/post", Amortis::Ui::ImpairmentPostHandler, name: "impairment_post"
      path "/impairments/<id:int>/delete", Amortis::Ui::ImpairmentDeleteHandler, name: "impairment_delete"
      path "/candidates", Amortis::Ui::CandidatesHandler, name: "candidates"
      path "/postings", Amortis::Ui::PostingsHandler, name: "postings"
      path "/postings/post", Amortis::Ui::PostingsPostHandler, name: "postings_post"
      path "/postings/<id:int>/cancel", Amortis::Ui::PostingCancelHandler, name: "posting_cancel"
      path "/statements", Amortis::Ui::StatementsHandler, name: "statements"
      path "/coefficients", Amortis::Ui::CoefficientsHandler, name: "coefficients"
      path "/settings", Amortis::Ui::SettingsHandler, name: "settings"
      path "/settings/accounts", Amortis::Ui::SettingsAccountsHandler, name: "settings_accounts"
    end

    # Routes qui inscrivent, modifient ou passent des écritures :
    # `amortis.write` ; réglages : `amortis.admin` ; les autres :
    # `amortis.read`. Le contrat vérifie encore les permissions du cœur
    # (écriture, extourne, création de compte).
    WRITE_ROUTES = %w[asset_new asset_edit asset_delete impairment_add dispose dispose_cancel dispose_post impairment_post
      impairment_delete postings_post posting_cancel]
    ADMIN_ROUTES = %w[settings settings_accounts]
  end
end

PartiduoUi::Extensions.mount Amortis::CODE, Amortis::Ui::ROUTES, permission: Amortis::Api::READ,
  permissions: Amortis::Ui::WRITE_ROUTES.to_h { |route| {route, Amortis::Api::WRITE} }
    .merge(Amortis::Ui::ADMIN_ROUTES.to_h { |route| {route, Amortis::Api::ADMIN} })

# Compteur du menu « Registre des immobilisations » et ligne de « À
# traiter » du tableau de bord : acquisitions à inscrire.
PartiduoUi::Extensions.counter("AMORTIS_ASSETS", route: "amortis:candidates", todo: "amortis_ui.todo", tone: "warn") do |actor|
  Amortis::Api.candidate_count(actor)
end
