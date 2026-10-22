# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Contrat public de l'extension des immobilisations et des amortissements,
  # sur le modèle de `Partiduo::Api` (DECISIONS C2 du cœur) : acteur en
  # premier argument, contrôle d'accès en première ligne (extension active,
  # dossier d'entreprise, permission), objets de vue immuables, toute
  # écriture par une commande qui rend un `Result` avec ses erreurs par
  # champ, dans une transaction. L'interface de l'extension (`ui/bulma/`)
  # ne voit que ce module et `Partiduo::Api` ; une extension qui en dépend
  # (télédéclaration, `depends_on "AMORTIS"`) l'emploie de même.
  #
  # Référence : `doc/api/amortis.adoc`.
  module Api
    alias Actor = Partiduo::Api::Actor
    alias Guard = Partiduo::Api::Guard
    alias Result = Partiduo::Api::Result
    alias FieldError = Partiduo::Api::FieldError
    alias Transaction = Partiduo::Api::Transaction

    MODULE_CODE = Amortis::CODE
    READ        = "amortis.read"
    WRITE       = "amortis.write"
    ADMIN       = "amortis.admin"

    # --- Réglages --------------------------------------------------------------------

    def self.settings(actor : Actor) : SettingsView
      authorize!(actor, READ)
      Settings.view
    end

    def self.update_settings(actor : Actor, input : SettingsInput) : Result(SettingsView)
      authorize!(actor, ADMIN)
      errors = Checks.settings_errors(input)
      return Result(SettingsView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Settings.row || Setting.new
        Settings.apply(row, input).save!
        Result(SettingsView).success(Settings.view)
      end
    end

    # Crée les comptes des réglages absents du plan comptable (D-AMO-012) ;
    # rend les numéros créés. Exige aussi `accounting.account.write`.
    def self.ensure_accounts(actor : Actor) : Result(Array(String))
      authorize!(actor, ADMIN)
      Guard.authorize!(actor, "accounting.account.write")
      view = Settings.view
      Transaction.run do
        created = [] of String
        errors = [] of FieldError
        view.accounts.each do |code, number|
          next if number.empty? || Accounts.exists?(number) || created.includes?(number)
          found = Accounts.create(actor, number, I18n.t("amortis.default_accounts.#{code}"))
          found.empty? ? (created << number) : errors.concat(found.map { |error| FieldError.new(code, error.key, error.params) })
        end
        errors.empty? ? Result(Array(String)).success(created) : Result(Array(String)).failure(errors)
      end
    end

    # Exercices du socle, du plus récent au plus ancien.
    def self.exercises(actor : Actor) : Array(ExerciseView)
      authorize!(actor, READ)
      closed = Records.closed_years
      Records.known_exercises.sort_by(&.starts_on).reverse!.map { |item| Records.exercise_view(item, closed) }
    end

    # Coefficients datés du dégressif français (D-AMO-006).
    def self.coefficients(actor : Actor) : Array(CoefficientView)
      authorize!(actor, READ)
      Coefficients::FR.map do |item|
        CoefficientView.new(item.from, item.before, item.short, item.medium, item.long, item.source)
      end
    end

    # --- Registre ----------------------------------------------------------------------

    def self.assets(actor : Actor, query : AssetQuery = AssetQuery.new) : Array(AssetView)
      authorize!(actor, READ)
      context = Schedules::Context.new
      rows = Asset.all.order(:code, :id).to_a
      rows = rows.select(&.parent_id.nil?) unless query.include_components
      if text = query.search.try(&.strip.downcase).presence
        rows = rows.select do |row|
          row.code.to_s.downcase.includes?(text) || row.label.to_s.downcase.includes?(text) ||
            row.asset_account.to_s.starts_with?(text)
        end
      end
      views = rows.map { |row| Schedules.asset_view(context, row) }
      query.status.try { |status| views = views.select(&.status.==(status)) }
      start = Math.max(query.offset, 0)
      views[start, query.limit.clamp(1, MAX_LIMIT)]? || [] of AssetView
    end

    def self.asset(actor : Actor, id : Int64) : AssetView
      authorize!(actor, READ)
      Schedules.asset_view(Schedules::Context.new, Records.asset!(id))
    end

    def self.components(actor : Actor, id : Int64) : Array(AssetView)
      authorize!(actor, READ)
      context = Schedules::Context.new
      Records.components(Records.asset!(id).id!.to_i64).map { |row| Schedules.asset_view(context, row) }
    end

    # Tableau d'amortissement d'une immobilisation (D-AMO-005).
    def self.schedule(actor : Actor, id : Int64) : ScheduleView
      authorize!(actor, READ)
      Schedules.schedule_view(Schedules::Context.new, Records.asset!(id))
    end

    # Plan d'une saisie non enregistrée (aperçu de l'écran), sans contrôle
    # des comptes : lignes, ou erreurs du plan.
    def self.preview_schedule(actor : Actor, input : AssetInput) : Result(Array(ScheduleRowView))
      authorize!(actor, READ)
      context = Schedules::Context.new
      errors = Checks.asset_errors(actor, context, input).select(&.field.in?("gross_value", "residual_value", "method",
        "life_months", "fiscal_method", "fiscal_life_months", "in_service_on"))
      return Result(Array(ScheduleRowView)).failure(errors) unless errors.empty?
      plan = Plan::Input.new(regime: context.regime, day_count: context.settings.day_count, acquired_on: input.acquired_on,
        in_service_on: input.in_service_on, gross: input.gross_value, residual: input.residual_value, method: input.method,
        life_months: input.life_months, fiscal_method: input.fiscal_method, fiscal_life_months: input.fiscal_life_months)
      from, to = Plan.horizon(plan)
      rows = Plan.rows(plan, context.exercises(from, to)).map do |item|
        ScheduleRowView.new(exercise: Records.exercise_view(item.exercise, context.closed),
          accounting_opening: item.accounting_opening, accounting: item.accounting, accounting_cumul: item.accounting_cumul,
          accounting_mode: item.accounting_mode, impairment: item.impairment, impairment_cumul: item.impairment_cumul,
          net_value: item.net_value, fiscal: item.fiscal, fiscal_cumul: item.fiscal_cumul, fiscal_mode: item.fiscal_mode,
          derogatory: item.derogatory, derogatory_cumul: item.derogatory_cumul, posted_depreciation: BigDecimal.new(0),
          posted_derogatory: BigDecimal.new(0), disposed: false)
      end
      Result(Array(ScheduleRowView)).success(rows)
    end

    def self.check_asset(actor : Actor, input : AssetInput, id : Int64? = nil) : Result(Nil)
      authorize!(actor, WRITE)
      errors = Checks.asset_errors(actor, Schedules::Context.new, input, id)
      errors.empty? ? Result(Nil).success(nil) : Result(Nil).failure(errors)
    end

    # Inscrit une immobilisation ou un composant (D-AMO-003). Crée les
    # comptes d'amortissements et de dépréciations manquants si
    # `create_accounts` et que l'acteur a `accounting.account.write`.
    #
    # Erreurs : `amortis.errors.asset.*`, `.asset_account.*`,
    # `.account.missing`, `.degressive.*`, `.choice.invalid` ; celles de la
    # Comptabilité pour la création d'un compte.
    def self.create_asset(actor : Actor, input : AssetInput) : Result(AssetView)
      authorize!(actor, WRITE)
      context = Schedules::Context.new
      errors = Checks.asset_errors(actor, context, input)
      return Result(AssetView).failure(errors) unless errors.empty?
      Transaction.run do
        row = Asset.new(created_by_id: actor.user_id)
        created = Checks.apply_asset(actor, context.regime, row, input)
        next Result(AssetView).failure(created) unless created.empty?
        row.save!
        Result(AssetView).success(Schedules.asset_view(context, row))
      end
    end

    # Modifie une immobilisation. Les champs du plan (comptes, dates,
    # valeurs, modes, durées, rattachement) sont figés tant qu'une écriture
    # d'inventaire non extournée la cite (`amortis.errors.asset.locked`).
    def self.update_asset(actor : Actor, id : Int64, input : AssetInput) : Result(AssetView)
      authorize!(actor, WRITE)
      context = Schedules::Context.new
      Transaction.run do
        row = Records.asset!(id, lock: true)
        errors = Checks.asset_errors(actor, context, input, id)
        next Result(AssetView).failure(errors) unless errors.empty?
        created = Checks.apply_asset(actor, context.regime, row, input)
        next Result(AssetView).failure(created) unless created.empty?
        row.save!
        Result(AssetView).success(Schedules.asset_view(Schedules::Context.new, row))
      end
    end

    # Supprime une immobilisation (et ses composants) qu'aucune écriture
    # d'inventaire n'a jamais citée.
    def self.delete_asset(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, WRITE)
      Transaction.run do
        row = Records.asset!(id, lock: true)
        ids = [id] + Records.components(id).map(&.id!.to_i64)
        if PostingLine.filter(asset_id__in: ids).exists? || Posting.filter(asset_id__in: ids).exists?
          next Result(Nil).failure(Records.error(FieldError::BASE, "asset.in_use"))
        end
        row.delete
        Result(Nil).success(nil)
      end
    end

    # --- Dépréciations ---------------------------------------------------------------

    def self.impairments(actor : Actor, asset_id : Int64) : Array(ImpairmentView)
      authorize!(actor, READ)
      Impairment.filter(asset_id: Records.asset!(asset_id).id).order(:date, :id).to_a.map { |row| Records.impairment_view(row) }
    end

    def self.impairment(actor : Actor, id : Int64) : ImpairmentView
      authorize!(actor, READ)
      Records.impairment_view(Records.impairment!(id))
    end

    # Enregistre une dépréciation (montant positif) ou une reprise (négatif)
    # (D-AMO-010) ; l'écriture se passe ensuite (`post_impairment`).
    def self.add_impairment(actor : Actor, asset_id : Int64, input : ImpairmentInput) : Result(ImpairmentView)
      authorize!(actor, WRITE)
      context = Schedules::Context.new
      Transaction.run do
        asset = Records.asset!(asset_id, lock: true)
        errors = Checks.impairment_errors(context, asset, input)
        next Result(ImpairmentView).failure(errors) unless errors.empty?
        row = Impairment.create!(asset_id: asset.id, date: input.date, amount: Plan.money(input.amount),
          label: input.label.strip, created_by_id: actor.user_id)
        Result(ImpairmentView).success(Records.impairment_view(row))
      end
    end

    # Supprime une dépréciation dont l'écriture n'est pas passée (ou a été
    # extournée).
    def self.delete_impairment(actor : Actor, id : Int64) : Result(Nil)
      authorize!(actor, WRITE)
      Transaction.run do
        row = Records.impairment!(id)
        if Posting.filter(impairment_id: id).exists?
          next Result(Nil).failure(Records.error(FieldError::BASE, "impairment.in_use"))
        end
        row.delete
        Result(Nil).success(nil)
      end
    end

    # --- Sorties -------------------------------------------------------------------------

    # Enregistre la cession ou la mise au rebut d'une immobilisation et de
    # ses composants encore présents (D-AMO-008) : le plan s'arrête à la
    # date de sortie ; l'écriture se passe ensuite (`post_disposal`).
    def self.dispose(actor : Actor, asset_id : Int64, input : DisposalInput) : Result(AssetView)
      authorize!(actor, WRITE)
      context = Schedules::Context.new
      Transaction.run do
        asset = Records.asset!(asset_id, lock: true)
        errors = Checks.disposal_errors(context, asset, input)
        next Result(AssetView).failure(errors) unless errors.empty?
        disposal = Disposal.create!(asset_id: asset.id, disposed_on: input.disposed_on, kind: input.kind,
          price: Plan.money(input.price), label: input.label.strip, created_by_id: actor.user_id)
        Records.components(asset_id).each do |component|
          next if Disposal.filter(asset_id: component.id).exists?
          Disposal.create!(asset_id: component.id, parent_disposal_id: disposal.id, disposed_on: input.disposed_on,
            kind: input.kind, price: BigDecimal.new(0), label: input.label.strip, created_by_id: actor.user_id)
        end
        Result(AssetView).success(Schedules.asset_view(Schedules::Context.new, asset))
      end
    end

    # Annule une sortie dont l'écriture n'est pas passée (ou a été
    # extournée), avec celle des composants sortis avec elle.
    def self.cancel_disposal(actor : Actor, asset_id : Int64) : Result(AssetView)
      authorize!(actor, WRITE)
      Transaction.run do
        asset = Records.asset!(asset_id, lock: true)
        disposal = Records.disposal_of(asset_id)
        next Result(AssetView).failure(Records.error(FieldError::BASE, "disposal.none")) if disposal.nil?
        next Result(AssetView).failure(Records.error(FieldError::BASE, "disposal.part_of_group")) if disposal.parent_disposal_id
        if Records.live_posting(disposal_id: disposal.id!.to_i64)
          next Result(AssetView).failure(Records.error(FieldError::BASE, "disposal.posted"))
        end
        ids = [disposal.id!.to_i64] + Disposal.filter(parent_disposal_id: disposal.id).pluck(:id).map(&.first.as(Int64))
        if Posting.filter(disposal_id__in: ids).exists?
          Posting.filter(disposal_id__in: ids).update(disposal_id: nil)
        end
        Disposal.filter(parent_disposal_id: disposal.id).delete
        disposal.delete
        Result(AssetView).success(Schedules.asset_view(Schedules::Context.new, asset))
      end
    end

    # --- Écritures d'inventaire ---------------------------------------------------------

    # Écriture des dotations proposée pour un exercice du socle (D-AMO-009) :
    # ce que les plans prévoient moins ce qui est déjà passé. Rien n'est
    # écrit.
    def self.proposal(actor : Actor, fiscal_year_id : Int64, ledger_id : Int64? = nil) : ProposalView
      authorize!(actor, READ)
      Postings.proposal(Schedules::Context.new, Records.fiscal_exercise(fiscal_year_id), nil, ledger_id)
    end

    # Passe l'écriture des dotations proposées de l'exercice (toutes, ou
    # celles de `input.asset_ids`) par `Partiduo::Api::Accounting.post_entry`
    # ; exige aussi `accounting.entry.post` et l'écriture dans le journal.
    #
    # Erreurs : `amortis.errors.posting.nothing`, `.posting.date.outside`,
    # `.ledger.*`, `.account.missing`, `.account.unset` ; celles de la
    # Comptabilité (période close…).
    def self.post_depreciation(actor : Actor, fiscal_year_id : Int64, input : PostInput = PostInput.new) : Result(PostingView)
      authorize!(actor, WRITE)
      Postings.post_depreciation(actor, Schedules::Context.new, Records.fiscal_exercise(fiscal_year_id), input)
    end

    def self.post_impairment(actor : Actor, impairment_id : Int64, input : PostInput = PostInput.new) : Result(PostingView)
      authorize!(actor, WRITE)
      Postings.post_impairment(actor, Schedules::Context.new, Records.impairment!(impairment_id), input)
    end

    # Écriture de sortie proposée (sans rien écrire) : ses lignes.
    def self.disposal_entry(actor : Actor, asset_id : Int64) : Array(EntryLineView)
      authorize!(actor, READ)
      context = Schedules::Context.new
      asset = Records.asset!(asset_id)
      disposal = context.disposal(asset_id)
      return [] of EntryLineView if disposal.nil? || disposal.parent_disposal_id
      Postings.disposal_builder(context, Postings.disposal_members(context, asset, disposal)).views
    end

    def self.post_disposal(actor : Actor, asset_id : Int64, input : PostInput = PostInput.new) : Result(PostingView)
      authorize!(actor, WRITE)
      Postings.post_disposal(actor, Schedules::Context.new, Records.asset!(asset_id), input)
    end

    # Écritures d'inventaire passées, des plus récentes aux plus anciennes ;
    # d'un exercice ou d'une immobilisation.
    def self.postings(actor : Actor, fiscal_year_id : Int64? = nil, asset_id : Int64? = nil) : Array(PostingView)
      authorize!(actor, READ)
      rows = Posting.all
      rows = rows.filter(fiscal_year_id: fiscal_year_id) if fiscal_year_id
      if asset_id
        ids = PostingLine.filter(asset_id: asset_id).pluck(:posting_id).map(&.first.as(Int64))
        rows = rows.filter(id__in: ids)
      end
      closed = Records.closed_years
      rows.order("-date", "-id").to_a.map { |row| Records.posting_view(row, closed) }
    end

    def self.posting(actor : Actor, id : Int64) : PostingView
      authorize!(actor, READ)
      Records.posting_view(Records.posting!(id), Records.closed_years)
    end

    # Annule une écriture d'inventaire par extourne (`cancel_entry`, à
    # `date` ou à celle de l'écriture) ; ses montants redeviennent à
    # proposer. Exige aussi `accounting.entry.cancel`.
    def self.cancel_posting(actor : Actor, id : Int64, date : Time? = nil) : Result(PostingView)
      authorize!(actor, WRITE)
      Postings.cancel(actor, Records.posting!(id), date)
    end

    # --- États -------------------------------------------------------------------------

    # Tableau des immobilisations et des amortissements d'un exercice
    # (2054, 2055 ; état belge) — D-AMO-013.
    def self.statement(actor : Actor, fiscal_year_id : Int64) : StatementView
      authorize!(actor, READ)
      Statements.statement(Schedules::Context.new, Records.fiscal_exercise(fiscal_year_id))
    end

    # Registre des immobilisations et des amortissements de la 2035
    # (D-AMO-014).
    def self.register(actor : Actor, fiscal_year_id : Int64) : RegisterView
      authorize!(actor, READ)
      Statements.register(Schedules::Context.new, Records.fiscal_exercise(fiscal_year_id))
    end

    # Annexes 2054 et 2055 (réel normal) et tableau 2033-C (simplifié) de
    # la liasse d'un exercice, en zones de TELEDEC (A-AMO-2, D-AMO-017,
    # D-AMO-021) : formulaire → zone → montant en euros entiers ;
    # `nil` hors de France ou si tout est nul. Fournies à
    # `Teledec::Api.register_annexes` par `src/partiduo-amortis/teledec.cr`.
    def self.liasse_annexes(actor : Actor, fiscal_year_id : Int64) : Hash(String, Hash(String, BigDecimal))?
      authorize!(actor, READ)
      Annexes.boxes(Statements.statement(Schedules::Context.new, Records.fiscal_exercise(fiscal_year_id)))
    end

    # Immobilisations de la 2035 de l'année `year` (A-AMO-3, D-AMO-018) :
    # registre fiscal de l'exercice clos cette année-là, au format du module
    # `liberal` ; `nil` hors de France, sans exercice ou sans immobilisation.
    # Source enregistrée auprès de `Partiduo::Api::Liberal` (`app.cr`).
    def self.liberal_assets(actor : Actor, year : Int32) : Partiduo::Api::Liberal::AssetSourceView?
      authorize!(actor, READ)
      LiberalSource.view(year)
    end

    # Acquisitions à inscrire (D-AMO-004, D-AMO-019). Exige aussi
    # `accounting.entry.read` (sinon : aucune).
    def self.candidates(actor : Actor) : Array(CandidateView)
      authorize!(actor, READ)
      Candidates.list(actor)
    end

    # Acquisition à inscrire de la ligne d'écriture `line_id`, relue par son
    # identifiant (`Accounting.entry_line`, D-AMO-019) ; `nil` si la ligne
    # n'est pas lisible, déjà citée, ou n'est pas une acquisition d'un
    # exercice ouvert.
    def self.candidate(actor : Actor, line_id : Int64) : CandidateView?
      authorize!(actor, READ)
      Candidates.find(actor, line_id)
    end

    # --- Tableau de bord ---------------------------------------------------------------

    # Tuile ; `nil` si l'extension est inactive ou l'acteur sans droit.
    def self.tile(actor : Actor) : TileView?
      return unless available?(actor)
      context = Schedules::Context.new
      views = Asset.all.to_a.map { |row| Schedules.asset_view(context, row) }
      in_service = views.select(&.status.in?("in_service", "depreciated"))
      TileView.new(in_service.size, in_service.sum(BigDecimal.new(0), &.net_value), Candidates.list(actor).size)
    end

    def self.candidate_count(actor : Actor) : Int64?
      return unless available?(actor)
      count = Candidates.list(actor).size.to_i64
      count.zero? ? nil : count
    end

    # --- Outils ------------------------------------------------------------------------

    # Extension active et lisible par l'acteur.
    private def self.available?(actor : Actor) : Bool
      Partiduo::Modules.active?(MODULE_CODE) && actor.can?(READ)
    end

    # Extension active et permission. Le dossier d'un foyer n'a pas
    # d'immobilisations : le manifeste l'en exclut (`incompatible_with_kind`,
    # D-AMO-020), le cœur refuse l'activation et le démarrage.
    private def self.authorize!(actor : Actor, permission : String) : Nil
      Guard.authorize!(actor, permission, module_code: MODULE_CODE)
    end
  end
end
