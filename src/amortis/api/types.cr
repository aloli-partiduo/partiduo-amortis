# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  module Api
    # Modes du plan comptable (D-AMO-005). Libellé : `amortis.methods.<code>`.
    METHODS = Plan::METHODS

    # Modes du plan fiscal ; `same` : celui du plan comptable, sans
    # dérogatoire. Libellé : `amortis.fiscal_methods.<code>`.
    FISCAL_METHODS = Plan::FISCAL_METHODS

    # Décompte des jours du prorata temporis (D-AMO-005). Libellé :
    # `amortis.day_counts.<code>`.
    DAY_COUNTS = Plan::DAY_COUNTS

    # Sorties d'actif (D-AMO-008). Libellé : `amortis.disposal_kinds.<code>`.
    DISPOSAL_KINDS = %w[sale scrap]

    # Écritures d'inventaire (D-AMO-009). Libellés :
    # `amortis.posting_kinds.<code>`, `amortis.posting_statuses.<code>`.
    POSTING_KINDS    = %w[depreciation impairment disposal]
    POSTING_STATUSES = %w[posted cancelled]

    # États d'une immobilisation. Libellé : `amortis.statuses.<code>`.
    STATUSES = %w[pending in_service depreciated disposed]

    # Comptes par défaut des réglages (D-AMO-011). Libellé :
    # `amortis.default_accounts.<code>`.
    DEFAULT_ACCOUNTS = %w[expense_account impairment_expense_account impairment_income_account derogatory_account
      derogatory_expense_account derogatory_income_account disposal_expense_account disposal_income_account
      disposal_receivable_account]

    # Durée la plus longue d'un plan, en mois (cent ans).
    MAX_MONTHS = 1200

    MAX_LIMIT = 1000

    # --- Entrées -------------------------------------------------------------------

    # Immobilisation ou composant (`parent_id`) à inscrire (D-AMO-003).
    #
    # * `code` : numéro d'inventaire ; vide : le suivant (`IMM-00001`) ;
    # * `asset_account` : compte d'immobilisation (classe 2) ;
    #   `depreciation_account`, `impairment_account` : vides, déduits du
    #   compte d'immobilisation (`28…`, `29…` ; `2x9` en Belgique) et créés
    #   s'ils manquent quand `create_accounts` et que l'acteur peut écrire
    #   au plan (`accounting.account.write`) ; `expense_account` : vide,
    #   celui des réglages ;
    # * `in_service_on` : mise en service, départ du linéaire ; vide :
    #   l'immobilisation n'est pas encore amortie ;
    # * `method`, `life_months` : plan comptable (durée d'usage) ;
    #   `fiscal_method`, `fiscal_life_months` : plan fiscal (France), source
    #   du dérogatoire ;
    # * `new_asset` : bien neuf, seul admis au dégressif français ;
    # * `entry_line_id` : ligne de l'écriture d'acquisition (débit d'un
    #   compte d'immobilisation), qui ne sera plus proposée à l'inscription.
    record AssetInput,
      label : String,
      asset_account : String,
      acquired_on : Time,
      gross_value : BigDecimal,
      code : String = "",
      in_service_on : Time? = nil,
      residual_value : BigDecimal = BigDecimal.new(0),
      method : String = "linear",
      life_months : Int32 = 0,
      fiscal_method : String = "same",
      fiscal_life_months : Int32? = nil,
      new_asset : Bool = true,
      depreciation_account : String = "",
      impairment_account : String = "",
      expense_account : String = "",
      parent_id : Int64? = nil,
      card_code : String = "",
      entry_line_id : Int64? = nil,
      notes : String = "",
      create_accounts : Bool = true

    # Dépréciation (positive) ou reprise (négative) à une date (D-AMO-010).
    record ImpairmentInput, date : Time, amount : BigDecimal, label : String = ""

    # Sortie : cession (`sale`, prix) ou mise au rebut (`scrap`).
    record DisposalInput, disposed_on : Time, kind : String = "sale", price : BigDecimal = BigDecimal.new(0),
      label : String = ""

    # Écriture d'inventaire à passer : journal d'opérations diverses (vide :
    # celui des réglages, sinon le premier) et date (vide : fin de
    # l'exercice pour les dotations, date de l'opération sinon) ;
    # `asset_ids` : seulement ces immobilisations (dotations).
    record PostInput, ledger_id : Int64? = nil, date : Time? = nil, asset_ids : Array(Int64)? = nil

    # Réglages (D-AMO-011). Comptes vides : ceux du régime.
    record SettingsInput,
      ledger_id : Int64? = nil,
      day_count : String = "actual",
      expense_account : String = "",
      impairment_expense_account : String = "",
      impairment_income_account : String = "",
      derogatory_account : String = "",
      derogatory_expense_account : String = "",
      derogatory_income_account : String = "",
      disposal_expense_account : String = "",
      disposal_income_account : String = "",
      disposal_receivable_account : String = "",
      be_individual : Bool = false

    # Recherche dans le registre : texte (numéro, désignation, compte),
    # état (`STATUSES`, `nil` : tous), composants compris ou non.
    record AssetQuery,
      search : String? = nil,
      status : String? = nil,
      include_components : Bool = true,
      offset : Int32 = 0,
      limit : Int32 = 500

    # --- Vues ----------------------------------------------------------------------

    # Exercice d'un plan ou d'un état : celui du socle (`fiscal_year_id`) ou
    # prolongé (D-AMO-005).
    record ExerciseView, label : String, starts_on : Time, ends_on : Time, fiscal_year_id : Int64?, closed : Bool = false

    record DisposalView,
      id : Int64,
      asset_id : Int64,
      parent_disposal_id : Int64?,
      disposed_on : Time,
      kind : String,
      price : BigDecimal,
      label : String,
      posting_id : Int64?,
      result : BigDecimal,
      short_term : BigDecimal,
      long_term : BigDecimal do
      def kind_key : String
        "amortis.disposal_kinds.#{kind}"
      end

      def posted? : Bool
        !posting_id.nil?
      end
    end

    record ImpairmentView,
      id : Int64,
      asset_id : Int64,
      date : Time,
      amount : BigDecimal,
      label : String,
      posting_id : Int64? do
      def posted? : Bool
        !posting_id.nil?
      end
    end

    # Immobilisation du registre, avec ses valeurs à la clôture de
    # l'exercice en cours (`as_of`).
    record AssetView,
      id : Int64,
      parent_id : Int64?,
      parent_code : String?,
      code : String,
      label : String,
      card_code : String,
      asset_account : String,
      depreciation_account : String,
      impairment_account : String,
      expense_account : String,
      expense_account_default : Bool,
      rubric : String,
      acquired_on : Time,
      in_service_on : Time?,
      gross_value : BigDecimal,
      residual_value : BigDecimal,
      method : String,
      life_months : Int32,
      fiscal_method : String,
      fiscal_life_months : Int32?,
      new_asset : Bool,
      coefficient : BigDecimal?,
      rate : BigDecimal?,
      entry_id : Int64?,
      entry_line_id : Int64?,
      notes : String,
      component_count : Int32,
      status : String,
      locked : Bool,
      as_of : Time,
      accounting_cumul : BigDecimal,
      impairment_cumul : BigDecimal,
      derogatory_cumul : BigDecimal,
      net_value : BigDecimal,
      disposal : DisposalView?,
      created_at : Time do
      def component? : Bool
        !parent_id.nil?
      end

      def disposed? : Bool
        !disposal.nil?
      end

      def derogatory? : Bool
        fiscal_method != "same"
      end

      def status_key : String
        "amortis.statuses.#{status}"
      end

      def method_key : String
        "amortis.methods.#{method}"
      end

      def fiscal_method_key : String
        "amortis.fiscal_methods.#{fiscal_method}"
      end

      def rubric_key : String
        "amortis.rubrics.#{rubric}"
      end
    end

    # Ligne du tableau d'amortissement d'une immobilisation (D-AMO-005) :
    # plan comptable, dépréciations, plan fiscal et dérogatoire, et ce qui
    # en est déjà passé en comptabilité pour l'exercice.
    record ScheduleRowView,
      exercise : ExerciseView,
      accounting_opening : BigDecimal,
      accounting : BigDecimal,
      accounting_cumul : BigDecimal,
      accounting_mode : String,
      impairment : BigDecimal,
      impairment_cumul : BigDecimal,
      net_value : BigDecimal,
      fiscal : BigDecimal,
      fiscal_cumul : BigDecimal,
      fiscal_mode : String,
      derogatory : BigDecimal,
      derogatory_cumul : BigDecimal,
      posted_depreciation : BigDecimal,
      posted_derogatory : BigDecimal,
      disposed : Bool do
      # Dotations de l'exercice entièrement passées.
      def posted? : Bool
        posted_depreciation == accounting && posted_derogatory == derogatory
      end
    end

    # Tableau d'amortissement d'une immobilisation, et résultat de sa sortie.
    record ScheduleView,
      asset : AssetView,
      rows : Array(ScheduleRowView),
      derogatory : Bool,
      disposal : DisposalView?

    # Montant d'une écriture proposée : compte, sens, montant, libellé.
    record EntryLineView, account : String, side : Partiduo::Api::Accounting::Side, amount : BigDecimal, label : String

    # Dotations proposées pour une immobilisation et un exercice : ce que le
    # plan prévoit moins ce qui est déjà passé.
    record ProposalLineView,
      asset_id : Int64,
      code : String,
      label : String,
      depreciation : BigDecimal,
      derogatory : BigDecimal,
      accounting_mode : String,
      expense_account : String,
      depreciation_account : String

    # Écriture d'inventaire proposée pour un exercice (D-AMO-009) : rien
    # n'est passé sans l'action de l'utilisateur. `blockers` : comptes
    # absents, journal manquant ; `disposals` : sorties de l'exercice dont
    # l'écriture reste à passer (leur dotation y figure).
    record ProposalView,
      exercise : ExerciseView,
      lines : Array(ProposalLineView),
      entry_lines : Array(EntryLineView),
      total_depreciation : BigDecimal,
      total_derogatory : BigDecimal,
      ledger_id : Int64?,
      date : Time,
      blockers : Array(Partiduo::Api::FieldError),
      disposals : Array(AssetView),
      impairments : Array(ImpairmentView) do
      def empty? : Bool
        lines.empty?
      end
    end

    # Écriture d'inventaire passée (D-AMO-009).
    record PostingView,
      id : Int64,
      kind : String,
      exercise : ExerciseView,
      date : Time,
      ledger_id : Int64,
      entry_id : Int64,
      amount : BigDecimal,
      status : String,
      reversal_entry_id : Int64?,
      asset_id : Int64?,
      asset_code : String?,
      asset_count : Int32,
      created_by_id : Int64?,
      created_at : Time do
      def cancelled? : Bool
        status == "cancelled"
      end

      def kind_key : String
        "amortis.posting_kinds.#{kind}"
      end

      def status_key : String
        "amortis.posting_statuses.#{status}"
      end
    end

    # Ligne d'un état des immobilisations et des amortissements, par
    # rubrique (D-AMO-013) : valeurs brutes (2054), amortissements (2055,
    # cadre A, ventilés par mode), dépréciations, dérogatoires (2055,
    # cadre B : différentiel de durée, mode dégressif).
    record StatementRowView,
      rubric : String,
      group : String,
      gross_opening : BigDecimal,
      gross_increase : BigDecimal,
      gross_decrease : BigDecimal,
      gross_closing : BigDecimal,
      depreciation_opening : BigDecimal,
      depreciation_charge : BigDecimal,
      depreciation_decrease : BigDecimal,
      depreciation_closing : BigDecimal,
      charge_linear : BigDecimal,
      charge_degressive : BigDecimal,
      impairment_opening : BigDecimal,
      impairment_charge : BigDecimal,
      impairment_release : BigDecimal,
      impairment_closing : BigDecimal,
      derogatory_opening : BigDecimal,
      derogatory_charge_duration : BigDecimal,
      derogatory_charge_degressive : BigDecimal,
      derogatory_release_duration : BigDecimal,
      derogatory_release_degressive : BigDecimal,
      derogatory_closing : BigDecimal,
      net_closing : BigDecimal do
      def rubric_key : String
        "amortis.rubrics.#{rubric}"
      end
    end

    # État des immobilisations et des amortissements d'un exercice :
    # annexes 2054 et 2055 de la liasse (France) ou état des immobilisations
    # de l'annexe des comptes annuels (Belgique, rubriques du PCMN).
    # `unposted` : dotations calculées mais pas encore passées en
    # comptabilité pour l'exercice.
    record StatementView,
      exercise : ExerciseView,
      regime : String,
      rows : Array(StatementRowView),
      total : StatementRowView,
      unposted : BigDecimal

    # Ligne du registre des immobilisations et des amortissements (2035 des
    # professions libérales, D-AMO-014) : plan fiscal.
    record RegisterRowView,
      asset_id : Int64,
      code : String,
      label : String,
      acquired_on : Time,
      in_service_on : Time?,
      base : BigDecimal,
      method : String,
      rate : BigDecimal?,
      prior : BigDecimal,
      charge : BigDecimal,
      cumul : BigDecimal,
      net_value : BigDecimal,
      disposed_on : Time?,
      price : BigDecimal?,
      short_term : BigDecimal?,
      long_term : BigDecimal?

    record RegisterView,
      exercise : ExerciseView,
      rows : Array(RegisterRowView),
      total_base : BigDecimal,
      total_prior : BigDecimal,
      total_charge : BigDecimal,
      total_net : BigDecimal,
      total_short_term : BigDecimal,
      total_long_term : BigDecimal

    # Ligne d'écriture au débit d'un compte d'immobilisation qu'aucune
    # immobilisation ne cite : acquisition à inscrire (D-AMO-004).
    record CandidateView,
      entry_id : Int64,
      line_id : Int64,
      date : Time,
      ledger_code : String,
      receipt : String?,
      label : String,
      account : String,
      account_label : String,
      amount : BigDecimal

    # Coefficient du dégressif français en vigueur à une date (D-AMO-006).
    record CoefficientView, from : Time, before : Time?, short : BigDecimal, medium : BigDecimal, long : BigDecimal,
      source : String

    record SettingsView,
      regime : String,
      ledger_id : Int64?,
      day_count : String,
      accounts : Hash(String, String),
      be_individual : Bool,
      stored : Bool do
      def account(code : String) : String
        accounts[code]? || ""
      end
    end

    # Tuile du tableau de bord : immobilisations en service, valeur nette,
    # acquisitions à inscrire.
    record TileView, in_service_count : Int32, net_value : BigDecimal, candidate_count : Int32
  end
end
