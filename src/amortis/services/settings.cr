# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Réglages du dossier et régime (D-AMO-011) : la ligne enregistrée, ou les
  # valeurs par défaut du régime (plan comptable français ou belge). Interne.
  module Settings
    alias Api = Amortis::Api

    # Comptes par défaut du Plan comptable général (France).
    FR = {
      "expense_account"             => "6811",
      "impairment_expense_account"  => "6816",
      "impairment_income_account"   => "7816",
      "derogatory_account"          => "145",
      "derogatory_expense_account"  => "6872",
      "derogatory_income_account"   => "7872",
      "disposal_expense_account"    => "675",
      "disposal_income_account"     => "775",
      "disposal_receivable_account" => "462",
    }

    # Comptes par défaut du PCMN (Belgique) : pas de dérogatoire ; la sortie
    # passe la plus-value (763) ou la moins-value (663) seules.
    BE = {
      "expense_account"             => "630",
      "impairment_expense_account"  => "630",
      "impairment_income_account"   => "760",
      "derogatory_account"          => "",
      "derogatory_expense_account"  => "",
      "derogatory_income_account"   => "",
      "disposal_expense_account"    => "663",
      "disposal_income_account"     => "763",
      "disposal_receivable_account" => "416",
    }

    def self.defaults(regime : String) : Hash(String, String)
      regime == "be" ? BE : FR
    end

    # Régime fiscal du dossier (`fr` ou `be`) ; `fr` par défaut.
    def self.regime : String
      Partiduo::Api::Core.settings(Partiduo::Api::Actor.system).tax_regime == "be" ? "be" : "fr"
    rescue Partiduo::Api::NotFound
      "fr"
    end

    # Dossier d'un foyer (ADR-011 A3) : l'extension n'y sert pas (D-AMO-002).
    def self.household? : Bool
      Partiduo::Api::Core.settings(Partiduo::Api::Actor.system).household?
    rescue Partiduo::Api::NotFound
      false
    end

    def self.row : Setting?
      Setting.all.order(:id).first
    end

    def self.view : Api::SettingsView
      regime = self.regime
      defaults = defaults(regime)
      stored = row
      accounts = Api::DEFAULT_ACCOUNTS.to_h do |code|
        value = stored.try { |item| account_of(item, code) } || ""
        {code, value.empty? ? defaults[code] : value}
      end
      Api::SettingsView.new(regime: regime, ledger_id: stored.try(&.ledger_id.try(&.to_i64)),
        day_count: stored.try(&.day_count.to_s) || "actual", accounts: accounts,
        be_individual: stored.try(&.be_individual) == true, stored: !stored.nil?)
    end

    def self.account_of(row : Setting, code : String) : String
      case code
      when "expense_account"             then row.expense_account.to_s
      when "impairment_expense_account"  then row.impairment_expense_account.to_s
      when "impairment_income_account"   then row.impairment_income_account.to_s
      when "derogatory_account"          then row.derogatory_account.to_s
      when "derogatory_expense_account"  then row.derogatory_expense_account.to_s
      when "derogatory_income_account"   then row.derogatory_income_account.to_s
      when "disposal_expense_account"    then row.disposal_expense_account.to_s
      when "disposal_income_account"     then row.disposal_income_account.to_s
      when "disposal_receivable_account" then row.disposal_receivable_account.to_s
      else                                    ""
      end
    end

    def self.apply(row : Setting, input : Api::SettingsInput) : Setting
      row.ledger_id = input.ledger_id
      row.day_count = input.day_count
      row.expense_account = input.expense_account.strip
      row.impairment_expense_account = input.impairment_expense_account.strip
      row.impairment_income_account = input.impairment_income_account.strip
      row.derogatory_account = input.derogatory_account.strip
      row.derogatory_expense_account = input.derogatory_expense_account.strip
      row.derogatory_income_account = input.derogatory_income_account.strip
      row.disposal_expense_account = input.disposal_expense_account.strip
      row.disposal_income_account = input.disposal_income_account.strip
      row.disposal_receivable_account = input.disposal_receivable_account.strip
      row.be_individual = input.be_individual
      row
    end

    def self.input_accounts(input : Api::SettingsInput) : Hash(String, String)
      {
        "expense_account"             => input.expense_account,
        "impairment_expense_account"  => input.impairment_expense_account,
        "impairment_income_account"   => input.impairment_income_account,
        "derogatory_account"          => input.derogatory_account,
        "derogatory_expense_account"  => input.derogatory_expense_account,
        "derogatory_income_account"   => input.derogatory_income_account,
        "disposal_expense_account"    => input.disposal_expense_account,
        "disposal_income_account"     => input.disposal_income_account,
        "disposal_receivable_account" => input.disposal_receivable_account,
      }
    end
  end
end
