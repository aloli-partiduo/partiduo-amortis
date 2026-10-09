# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Comptes de l'inventaire des immobilisations (D-AMO-012) : comptes
  # d'amortissements et de dépréciations déduits du compte
  # d'immobilisation, comptes par défaut, création des comptes manquants
  # par le contrat de la Comptabilité (`create_account`, avec les droits de
  # l'acteur). Interne.
  module Accounts
    alias Acc = Partiduo::Api::Accounting
    alias Kind = Partiduo::Api::Accounting::AccountKind

    # Compte d'immobilisation amortissable ou non : classe 2, hors
    # amortissements et dépréciations (`28`, `29` en France ; `2x9` et les
    # créances à plus d'un an `29` en Belgique).
    def self.asset_account?(regime : String, number : String) : Bool
      return false unless number.starts_with?('2') && number.size >= 2
      if regime == "be"
        !number.starts_with?("29") && !(number.size >= 4 && number[3] == '9')
      else
        !number.starts_with?("28") && !number.starts_with?("29")
      end
    end

    # Compte d'amortissements : `28` + suite du numéro (`2154` → `28154`)
    # en France ; `2x9` (`240` → `2409`) en Belgique.
    def self.depreciation_for(regime : String, asset_account : String) : String
      return "" unless asset_account.size >= 3
      regime == "be" ? "#{asset_account[0, 3]}9" : "28#{asset_account[1..]}"
    end

    # Compte de dépréciations : `29` + suite du numéro en France ; le compte
    # d'amortissements et de réductions de valeur actés en Belgique.
    def self.impairment_for(regime : String, asset_account : String) : String
      return "" unless asset_account.size >= 3
      regime == "be" ? depreciation_for(regime, asset_account) : "29#{asset_account[1..]}"
    end

    # Type d'un compte que l'extension crée, d'après son numéro.
    def self.kind_for(number : String) : Kind
      case number
      when .starts_with?("28"), .starts_with?("29"), /\A2\d\d9/ then Kind::AssetContra
      when .starts_with?('1')                                   then Kind::Liability
      when .starts_with?('2'), .starts_with?('4')               then Kind::Asset
      when .starts_with?('6')                                   then Kind::Expense
      when .starts_with?('7')                                   then Kind::Income
      else                                                           Kind::Context
      end
    end

    # Le compte existe-t-il ? Lu avec l'acteur système : seul le numéro est
    # cherché, pas son contenu.
    def self.exists?(number : String) : Bool
      Acc.account(Partiduo::Api::Actor.system, number)
      true
    rescue Partiduo::Api::NotFound
      false
    end

    def self.label(number : String) : String?
      Acc.account(Partiduo::Api::Actor.system, number).label
    rescue Partiduo::Api::NotFound
      nil
    end

    # Crée le compte avec les droits de l'acteur ; rend les erreurs.
    def self.create(actor : Partiduo::Api::Actor, number : String, label : String) : Array(Partiduo::Api::FieldError)
      result = Acc.create_account(actor, Acc::AccountInput.new(number: number, label: label[0, 200], kind: kind_for(number)))
      result.success? ? [] of Partiduo::Api::FieldError : result.errors
    end

    # Comptes par défaut du régime absents du plan, créés à l'activation
    # d'un dossier neuf (données initiales) ou par l'écran des réglages.
    # Rend les numéros créés.
    def self.ensure_defaults(actor : Partiduo::Api::Actor, regime : String, locale : String) : Array(String)
      created = [] of String
      I18n.with_locale(Partiduo::LOCALES.includes?(locale) ? locale : "fr") do
        Settings.defaults(regime).each do |code, number|
          next if number.empty? || exists?(number)
          errors = create(actor, number, I18n.t("amortis.default_accounts.#{code}"))
          created << number if errors.empty?
        end
      end
      created
    end
  end
end
