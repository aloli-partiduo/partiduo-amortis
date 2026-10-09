# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Règles de saisie des immobilisations, dépréciations, sorties et
  # réglages (interne). Les erreurs sont des `FieldError` aux clés
  # `amortis.errors.*`.
  module Checks
    alias Api = Amortis::Api
    alias FieldError = Partiduo::Api::FieldError
    alias D = BigDecimal

    ZERO = BigDecimal.new(0)

    # Champs qui font le plan : figés dès qu'une écriture non extournée
    # cite l'immobilisation (D-AMO-009).
    PLAN_FIELDS = %w[asset_account depreciation_account impairment_account expense_account acquired_on in_service_on
      gross_value residual_value method life_months fiscal_method fiscal_life_months new_asset parent_id]

    # Comptes de l'immobilisation, déduits s'ils sont vides.
    record Accounts, depreciation : String, impairment : String, expense : String

    def self.accounts(regime : String, input : Api::AssetInput) : Accounts
      asset = input.asset_account.strip
      depreciation = input.depreciation_account.strip.presence ||
                     (input.method == "none" ? "" : Amortis::Accounts.depreciation_for(regime, asset))
      impairment = input.impairment_account.strip.presence || Amortis::Accounts.impairment_for(regime, asset)
      Accounts.new(depreciation, impairment, input.expense_account.strip)
    end

    def self.asset_errors(actor : Partiduo::Api::Actor, context : Schedules::Context, input : Api::AssetInput,
                          id : Int64? = nil) : Array(FieldError)
      errors = [] of FieldError
      regime = context.regime
      text_errors(input, id, errors)
      account_errors(actor, regime, input, errors)
      plan_errors(context, input, errors)
      link_errors(actor, input, id, errors)
      if id && Records.locked?(id) && (row = Asset.filter(id: id).first)
        changed = changed_plan_fields(regime, row, input)
        errors << Records.error(changed.first, "asset.locked") unless changed.empty?
      end
      errors
    end

    private def self.text_errors(input : Api::AssetInput, id : Int64?, errors : Array(FieldError)) : Nil
      label = input.label.strip
      if label.empty?
        errors << Records.error("label", "asset.label.blank")
      elsif label.size > 255
        errors << Records.error("label", "asset.label.too_long", {"max" => "255"})
      end
      code = input.code.strip
      if code.size > 30
        errors << Records.error("code", "asset.code.too_long", {"max" => "30"})
      elsif !code.empty? && Asset.all.to_a.any? { |row| row.id != id && row.code.to_s.downcase == code.downcase }
        errors << Records.error("code", "asset.code.taken", {"code" => code})
      end
      errors << Records.error("notes", "asset.notes.too_long", {"max" => "4000"}) if input.notes.size > 4000
    end

    private def self.account_errors(actor : Partiduo::Api::Actor, regime : String, input : Api::AssetInput,
                                    errors : Array(FieldError)) : Nil
      asset = input.asset_account.strip
      if asset.empty?
        errors << Records.error("asset_account", "asset_account.blank")
        return
      elsif !Amortis::Accounts.asset_account?(regime, asset)
        errors << Records.error("asset_account", "asset_account.invalid", {"number" => asset})
        return
      elsif !Amortis::Accounts.exists?(asset)
        errors << Records.error("asset_account", "account.missing", {"number" => asset})
        return
      end
      accounts = accounts(regime, input)
      can_create = input.create_accounts && actor.can?("accounting.account.write")
      {"depreciation_account" => accounts.depreciation, "impairment_account" => accounts.impairment}.each do |field, number|
        next if number.empty? || Amortis::Accounts.exists?(number) || can_create
        errors << Records.error(field, "account.missing", {"number" => number})
      end
      if !accounts.expense.empty? && !Amortis::Accounts.exists?(accounts.expense)
        errors << Records.error("expense_account", "account.missing", {"number" => accounts.expense})
      end
    end

    private def self.plan_errors(context : Schedules::Context, input : Api::AssetInput, errors : Array(FieldError)) : Nil
      regime = context.regime
      errors << Records.error("gross_value", "asset.gross_value.positive") unless input.gross_value > 0
      if input.residual_value < 0 || input.residual_value >= input.gross_value
        errors << Records.error("residual_value", "asset.residual_value.range")
      end
      choice(errors, "method", input.method, Api::METHODS)
      choice(errors, "fiscal_method", input.fiscal_method, Api::FISCAL_METHODS)
      if input.method != "none" && !(1..Api::MAX_MONTHS).includes?(input.life_months)
        errors << Records.error("life_months", "asset.life_months.range", {"max" => Api::MAX_MONTHS.to_s})
      end
      fiscal_errors(regime, input, errors)
      if (service = input.in_service_on) && service < input.acquired_on
        errors << Records.error("in_service_on", "asset.in_service_on.before_acquisition")
      end
      degressive_errors(context, input, "method", input.method, input.life_months, errors)
      if input.fiscal_method == "degressive"
        degressive_errors(context, input, "fiscal_method", "degressive", input.fiscal_life_months || 0, errors)
      end
    end

    # Plan fiscal distinct : France seulement, bien amortissable, durée.
    private def self.fiscal_errors(regime : String, input : Api::AssetInput, errors : Array(FieldError)) : Nil
      return if input.fiscal_method == "same"
      if regime == "be"
        errors << Records.error("fiscal_method", "asset.fiscal_method.be")
      elsif input.method == "none"
        errors << Records.error("fiscal_method", "asset.fiscal_method.not_depreciable")
      elsif !(1..Api::MAX_MONTHS).includes?(input.fiscal_life_months || 0)
        errors << Records.error("fiscal_life_months", "asset.life_months.range", {"max" => Api::MAX_MONTHS.to_s})
      end
    end

    # Dégressif : trois ans au moins et bien neuf en France (D-AMO-006) ;
    # supprimé en Belgique pour les sociétés depuis 2020, sauf
    # contribuable personne physique (réglage).
    private def self.degressive_errors(context : Schedules::Context, input : Api::AssetInput, field : String,
                                       method : String, months : Int32, errors : Array(FieldError)) : Nil
      return unless method == "degressive"
      if context.regime == "be"
        if input.acquired_on >= Coefficients::BE_ABOLISHED_ON && !context.settings.be_individual
          errors << Records.error(field, "degressive.be_abolished")
        end
      elsif months < Coefficients::MIN_MONTHS
        errors << Records.error(field, "degressive.too_short")
      elsif !input.new_asset
        errors << Records.error(field, "degressive.used_asset")
      end
    end

    private def self.link_errors(actor : Partiduo::Api::Actor, input : Api::AssetInput, id : Int64?,
                                 errors : Array(FieldError)) : Nil
      input.parent_id.try { |parent_id| parent_errors(parent_id, id, errors) }
      if line_id = input.entry_line_id
        linked = Asset.filter(entry_line_id: line_id).to_a
        if linked.any? { |row| row.id != id }
          errors << Records.error("entry_line_id", "asset.entry_line.taken")
        elsif linked.empty? && Candidates.find(actor, line_id).nil?
          errors << Records.error("entry_line_id", "asset.entry_line.unknown")
        end
      end
      code = input.card_code.strip
      if !code.empty? && Partiduo::Api::Cards.card_by_code(Records.system, code).nil?
        errors << Records.error("card_code", "asset.card.unknown", {"code" => code})
      end
    end

    # Immobilisation principale : existante, elle-même sans parent, présente
    # à l'actif ; l'immobilisation rattachée n'a pas de composants.
    private def self.parent_errors(parent_id : Int64, id : Int64?, errors : Array(FieldError)) : Nil
      parent = Asset.filter(id: parent_id).first
      if parent.nil? || parent_id == id
        errors << Records.error("parent_id", "asset.parent.invalid")
      elsif parent.parent_id || (id && Asset.filter(parent_id: id).exists?)
        errors << Records.error("parent_id", "asset.parent.nested")
      elsif Disposal.filter(asset_id: parent_id).exists?
        errors << Records.error("parent_id", "asset.parent.disposed")
      end
    end

    def self.changed_plan_fields(regime : String, row : Asset, input : Api::AssetInput) : Array(String)
      accounts = accounts(regime, input)
      current = {
        "asset_account" => row.asset_account.to_s, "depreciation_account" => row.depreciation_account.to_s,
        "impairment_account" => row.impairment_account.to_s, "expense_account" => row.expense_account.to_s,
        "acquired_on" => Records.iso(row.acquired_on!), "in_service_on" => row.in_service_on.try { |day| Records.iso(day) } || "",
        "gross_value" => row.gross_value!.to_s, "residual_value" => (row.residual_value || ZERO).to_s,
        "method" => row.method.to_s, "life_months" => (row.life_months || 0).to_s, "fiscal_method" => row.fiscal_method.to_s,
        "fiscal_life_months" => row.fiscal_life_months.to_s, "new_asset" => (row.new_asset == true).to_s,
        "parent_id" => row.parent_id.to_s,
      }
      wanted = {
        "asset_account" => input.asset_account.strip, "depreciation_account" => accounts.depreciation,
        "impairment_account" => accounts.impairment, "expense_account" => accounts.expense,
        "acquired_on" => Records.iso(input.acquired_on), "in_service_on" => input.in_service_on.try { |day| Records.iso(day) } || "",
        "gross_value" => input.gross_value.to_s, "residual_value" => input.residual_value.to_s, "method" => input.method,
        "life_months" => (input.method == "none" ? 0 : input.life_months).to_s, "fiscal_method" => input.fiscal_method,
        "fiscal_life_months" => (input.fiscal_method == "same" ? nil : input.fiscal_life_months).to_s,
        "new_asset" => input.new_asset.to_s, "parent_id" => input.parent_id.to_s,
      }
      PLAN_FIELDS.reject { |field| same_value?(current[field], wanted[field]) }
    end

    private def self.same_value?(left : String, right : String) : Bool
      return true if left == right
      pattern = /\A-?\d+(\.\d+)?\z/
      left.matches?(pattern) && right.matches?(pattern) && BigDecimal.new(left) == BigDecimal.new(right)
    end

    # Applique la saisie ; crée les comptes d'amortissements et de
    # dépréciations manquants (avec les droits de l'acteur). Rend les
    # erreurs de création.
    def self.apply_asset(actor : Partiduo::Api::Actor, regime : String, row : Asset, input : Api::AssetInput) : Array(FieldError)
      accounts = accounts(regime, input)
      errors = [] of FieldError
      asset_label = Amortis::Accounts.label(input.asset_account.strip) || input.label.strip
      {
        {"depreciation_account", accounts.depreciation, "amortis.accounts.depreciation_of"},
        {"impairment_account", accounts.impairment, "amortis.accounts.impairment_of"},
      }.each do |(field, number, key)|
        next if number.empty? || Amortis::Accounts.exists?(number)
        created = Amortis::Accounts.create(actor, number, I18n.t(key, label: asset_label))
        errors.concat(created.map { |error| FieldError.new(field, error.key, error.params) })
      end
      return errors unless errors.empty?
      row.code = input.code.strip.presence || next_code
      row.label = input.label.strip
      row.card_code = input.card_code.strip.empty? ? "" : Partiduo::Api::Cards.format_code(input.card_code.strip)
      row.asset_account = input.asset_account.strip
      row.depreciation_account = accounts.depreciation
      row.impairment_account = accounts.impairment
      row.expense_account = accounts.expense
      row.acquired_on = input.acquired_on
      row.in_service_on = input.in_service_on
      row.gross_value = Plan.money(input.gross_value)
      row.residual_value = Plan.money(input.residual_value)
      row.method = input.method
      row.life_months = input.method == "none" ? 0 : input.life_months
      row.fiscal_method = input.fiscal_method
      row.fiscal_life_months = input.fiscal_method == "same" ? nil : input.fiscal_life_months
      row.new_asset = input.new_asset
      row.parent_id = input.parent_id
      if input.entry_line_id != row.entry_line_id
        row.entry_id = input.entry_line_id.try { |line_id| entry_of_line(actor, line_id) }
      end
      row.entry_line_id = input.entry_line_id
      row.notes = input.notes
      errors
    end

    # Numéro d'inventaire suivant : `IMM-` et cinq chiffres.
    def self.next_code : String
      numbers = Asset.all.to_a.compact_map { |row| row.code.to_s.match(/\AIMM-(\d+)\z/i).try(&.[1].to_i?) }
      "IMM-#{((numbers.max? || 0) + 1).to_s.rjust(5, '0')}"
    end

    private def self.entry_of_line(actor : Partiduo::Api::Actor, line_id : Int64) : Int64?
      Candidates.find(actor, line_id).try(&.entry_id)
    end

    # --- Dépréciations et sorties --------------------------------------------------

    def self.impairment_errors(context : Schedules::Context, row : Asset, input : Api::ImpairmentInput) : Array(FieldError)
      errors = [] of FieldError
      errors << Records.error("amount", "impairment.amount.zero") if input.amount.zero?
      errors << Records.error("label", "impairment.label.too_long", {"max" => "255"}) if input.label.strip.size > 255
      errors << Records.error("date", "impairment.date.before_acquisition") if input.date < row.acquired_on!
      if disposal = context.disposal(row.id!.to_i64)
        errors << Records.error("date", "impairment.date.after_disposal") if input.date > disposal.disposed_on!
      end
      impairment_amount_errors(context, row, input, errors) if errors.empty?
      errors
    end

    # Une dépréciation ne dépasse pas la valeur nette ; une reprise, les
    # dépréciations constatées.
    private def self.impairment_amount_errors(context : Schedules::Context, row : Asset, input : Api::ImpairmentInput,
                                              errors : Array(FieldError)) : Nil
      at = Schedules.row_at(Schedules.rows(context, row), input.date)
      accounting = at.try(&.accounting_cumul) || ZERO
      existing = context.impairments(row.id!.to_i64).sum(ZERO) { |item| item.amount || ZERO }
      if input.amount > 0 && row.gross_value! - accounting - existing - input.amount < 0
        errors << Records.error("amount", "impairment.amount.too_large")
      elsif input.amount < 0 && existing + input.amount < 0
        errors << Records.error("amount", "impairment.amount.release_too_large")
      end
    end

    def self.disposal_errors(context : Schedules::Context, row : Asset, input : Api::DisposalInput) : Array(FieldError)
      errors = [] of FieldError
      id = row.id!.to_i64
      errors << Records.error(FieldError::BASE, "disposal.exists") if context.disposal(id)
      choice(errors, "kind", input.kind, Api::DISPOSAL_KINDS)
      errors << Records.error("price", "disposal.price.negative") if input.price < 0
      errors << Records.error("price", "disposal.price.scrap") if input.kind == "scrap" && !input.price.zero?
      errors << Records.error("label", "disposal.label.too_long", {"max" => "255"}) if input.label.strip.size > 255
      disposal_date_errors(context, row, input.disposed_on, errors)
      errors
    end

    # Date de sortie : après l'acquisition et les dépréciations, et aucune
    # dotation passée pour un exercice postérieur.
    private def self.disposal_date_errors(context : Schedules::Context, row : Asset, day : Time,
                                          errors : Array(FieldError)) : Nil
      id = row.id!.to_i64
      errors << Records.error("disposed_on", "disposal.date.before_acquisition") if day < row.acquired_on!
      ids = [id] + Asset.filter(parent_id: id).pluck(:id).map(&.first.as(Int64))
      if context.impairments(id).any? { |item| item.date! > day }
        errors << Records.error("disposed_on", "disposal.date.impairment_after")
      end
      exercise = context.exercise_on(day)
      later = PostingLine.filter(asset_id__in: ids, exercise_start__gt: exercise.starts_on).to_a.any? do |line|
        Posting.filter(id: line.posting_id, status: "posted").exists?
      end
      errors << Records.error("disposed_on", "disposal.date.later_posted") if later
    end

    # --- Réglages --------------------------------------------------------------------

    def self.settings_errors(input : Api::SettingsInput) : Array(FieldError)
      errors = [] of FieldError
      choice(errors, "day_count", input.day_count, Api::DAY_COUNTS)
      if ledger_id = input.ledger_id
        ledger = Partiduo::Api::Accounting.ledger(Records.system, ledger_id) rescue nil
        if ledger.nil? || !ledger.kind.misc?
          errors << Records.error("ledger_id", "ledger.invalid")
        end
      end
      Settings.input_accounts(input).each do |field, number|
        number = number.strip
        next if number.empty? || Amortis::Accounts.exists?(number)
        errors << Records.error(field, "account.missing", {"number" => number})
      end
      errors
    end

    def self.choice(errors : Array(FieldError), field : String, value : String, allowed : Array(String)) : Nil
      errors << Records.error(field, "choice.invalid", {"value" => value}) unless allowed.includes?(value)
    end
  end
end
