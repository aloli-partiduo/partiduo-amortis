# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Lecture des lignes, exercices et construction des vues du contrat
  # (interne).
  module Records
    alias Api = Amortis::Api
    alias FieldError = Partiduo::Api::FieldError
    alias D = BigDecimal

    ZERO = BigDecimal.new(0)

    def self.error(field : String, key : String, params : Hash(String, String) = {} of String => String) : FieldError
      FieldError.new(field, "amortis.errors.#{key}", params)
    end

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def self.today : Time
      Partiduo::Api::Core.today
    end

    def self.iso(day : Time) : String
      day.to_s("%Y-%m-%d")
    end

    # --- Recherche ---------------------------------------------------------------

    def self.asset!(id : Int64, lock : Bool = false) : Asset
      query = Asset.filter(id: id)
      query = query.lock if lock
      query.first || raise Partiduo::Api::NotFound.new("amortis_asset", id)
    end

    def self.impairment!(id : Int64) : Impairment
      Impairment.filter(id: id).first || raise Partiduo::Api::NotFound.new("amortis_impairment", id)
    end

    def self.posting!(id : Int64) : Posting
      Posting.filter(id: id).first || raise Partiduo::Api::NotFound.new("amortis_posting", id)
    end

    def self.disposal_of(asset_id : Int64) : Disposal?
      Disposal.filter(asset_id: asset_id).first
    end

    def self.components(asset_id : Int64) : Array(Asset)
      Asset.filter(parent_id: asset_id).order(:code, :id).to_a
    end

    # Écriture d'inventaire non extournée d'une dépréciation, d'une sortie.
    def self.live_posting(impairment_id : Int64? = nil, disposal_id : Int64? = nil) : Posting?
      query = Posting.filter(status: "posted")
      query = query.filter(impairment_id: impairment_id) if impairment_id
      query = query.filter(disposal_id: disposal_id) if disposal_id
      query.first
    end

    # Une écriture non extournée cite-t-elle l'immobilisation ?
    def self.locked?(asset_id : Int64) : Bool
      posting_ids = PostingLine.filter(asset_id: asset_id).pluck(:posting_id).map(&.first.as(Int64))
      !posting_ids.empty? && Posting.filter(id__in: posting_ids, status: "posted").exists?
    end

    # Montants déjà passés, par immobilisation et début d'exercice
    # (écritures non extournées).
    def self.posted_amounts(asset_ids : Array(Int64)) : Hash({Int64, String}, {D, D})
      totals = {} of {Int64, String} => {D, D}
      return totals if asset_ids.empty?
      live = Posting.filter(status: "posted").pluck(:id).map(&.first.as(Int64)).to_set
      PostingLine.filter(asset_id__in: asset_ids).to_a.each do |line|
        next unless live.includes?(line.posting_id!.to_i64)
        key = {line.asset_id!.to_i64, iso(line.exercise_start!)}
        depreciation, derogatory = totals[key]? || {ZERO, ZERO}
        totals[key] = {depreciation + (line.depreciation || ZERO), derogatory + (line.derogatory || ZERO)}
      end
      totals
    end

    # --- Exercices ---------------------------------------------------------------

    # Exercices du socle (avec leurs périodes).
    def self.known_exercises : Array(Exercise)
      Partiduo::Api::Core.fiscal_years(system).compact_map do |year|
        starts, ends = year.starts_on, year.ends_on
        Exercise.new(starts, ends, year.id, year.label) if starts && ends
      end
    end

    def self.closed_years : Set(Int64)
      Partiduo::Api::Core.fiscal_years(system).select(&.closed?).map(&.id).to_set
    end

    def self.exercise_view(exercise : Exercise, closed : Set(Int64) = Set(Int64).new) : Api::ExerciseView
      Api::ExerciseView.new(exercise.display_label, exercise.starts_on, exercise.ends_on, exercise.fiscal_year_id,
        exercise.fiscal_year_id.try { |id| closed.includes?(id) } || false)
    end

    # Exercice du socle par son identifiant ; `NotFound` sinon.
    def self.fiscal_exercise(fiscal_year_id : Int64) : Exercise
      known_exercises.find(&.fiscal_year_id.==(fiscal_year_id)) || raise Partiduo::Api::NotFound.new("fiscal_year", fiscal_year_id)
    end

    # Exercice (connu ou prolongé) qui contient le jour.
    def self.exercise_on(day : Time, known : Array(Exercise) = known_exercises) : Exercise
      Calendar.find(Calendar.exercises(known, day, day), day) || Exercise.new(Time.utc(day.year, 1, 1), Time.utc(day.year, 12, 31))
    end

    # --- Vues --------------------------------------------------------------------

    def self.disposal_view(row : Disposal, result : Plan::DisposalResult?) : Api::DisposalView
      Api::DisposalView.new(id: row.id!.to_i64, asset_id: row.asset_id!.to_i64,
        parent_disposal_id: row.parent_disposal_id.try(&.to_i64), disposed_on: row.disposed_on!, kind: row.kind.to_s,
        price: row.price || ZERO, label: row.label.to_s, posting_id: live_posting(disposal_id: row.id!.to_i64).try(&.id!.to_i64),
        result: result.try(&.result) || ZERO, short_term: result.try(&.short_term) || ZERO,
        long_term: result.try(&.long_term) || ZERO)
    end

    def self.impairment_view(row : Impairment) : Api::ImpairmentView
      Api::ImpairmentView.new(id: row.id!.to_i64, asset_id: row.asset_id!.to_i64, date: row.date!, amount: row.amount!,
        label: row.label.to_s, posting_id: live_posting(impairment_id: row.id!.to_i64).try(&.id!.to_i64))
    end

    def self.posting_view(row : Posting, closed : Set(Int64) = Set(Int64).new) : Api::PostingView
      lines = PostingLine.filter(posting_id: row.id).to_a
      asset_id = row.asset_id.try(&.to_i64)
      exercise = Exercise.new(row.exercise_start!, row.exercise_end!, row.fiscal_year_id.try(&.to_i64),
        exercise_label(row))
      Api::PostingView.new(id: row.id!.to_i64, kind: row.kind.to_s, exercise: exercise_view(exercise, closed),
        date: row.date!, ledger_id: row.ledger_id!.to_i64, entry_id: row.entry_id!.to_i64, amount: row.amount || ZERO,
        status: row.status.to_s, reversal_entry_id: row.reversal_entry_id.try(&.to_i64), asset_id: asset_id,
        asset_code: asset_id.try { |id| Asset.filter(id: id).first.try(&.code.to_s) },
        asset_count: lines.map(&.asset_id).uniq!.size, created_by_id: row.created_by_id.try(&.to_i64),
        created_at: row.created_at || Time.utc)
    end

    private def self.exercise_label(row : Posting) : String
      fiscal_year_id = row.fiscal_year_id.try(&.to_i64)
      return "" if fiscal_year_id.nil?
      known_exercises.find(&.fiscal_year_id.==(fiscal_year_id)).try(&.label) || ""
    end
  end
end
