# SPDX-License-Identifier: AGPL-3.0-or-later

# Valeur attendue présente : échoue clairement sinon (plutôt que `not_nil!`).
def present(value : T?) : T forall T
  value.nil? ? raise("valeur attendue, nil obtenu") : value
end

module Amortis
  # Outils des specs : dossier provisionné par le contrat du cœur (plan
  # comptable du régime, journal d'opérations diverses O01), extension
  # activée avant le provisionnement (ses comptes par défaut sont créés par
  # les données initiales), exercices 2025 à 2027, acteurs, immobilisations.
  module SpecSupport
    alias Api = Amortis::Api
    alias Acc = Partiduo::Api::Accounting

    # Permissions du cœur d'un comptable qui inscrit et passe les écritures.
    CORE_PERMISSIONS = ["accounting.ledger.read", "accounting.entry.read", "accounting.entry.post",
                        "accounting.entry.cancel", "accounting.account.read", "accounting.account.write",
                        "cards.card.read"]

    def self.system : Partiduo::Api::Actor
      Partiduo::Api::Actor.system
    end

    def self.d(text : String) : BigDecimal
      BigDecimal.new(text)
    end

    def self.date(text : String) : Time
      Time.parse_utc(text, "%Y-%m-%d")
    end

    # Dossier du régime, exercices 2025, 2026 et 2027, utilisateurs de test,
    # extension active.
    def self.setup(regime : String = "fr") : Nil
      activate
      PartiduoUi::Reference.provision(regime)
      [2025, 2026, 2027].each { |year| PartiduoUi::Reference.fiscal_year(year) }
      user("alice@example.com", "Alice")
      user("bruno@example.com", "Bruno")
    end

    def self.activate : Nil
      Partiduo::Api::Modules.activate(system, Amortis::CODE).value!
    end

    def self.user(email : String, first_name : String) : Int64
      input = Partiduo::Api::Auth::UserInput.new(email: email, first_name: first_name, last_name: "Test", role: "member",
        profile_id: PartiduoUi::Accounts.profile_id("ADMIN"), password: PartiduoUi::Accounts::PASSWORD)
      Partiduo::Api::Auth.create_user(system, input).value!.user.id
    end

    def self.user_id(email : String) : Int64
      Partiduo::Api::Auth.user_by_email(system, email).try(&.id) || raise "utilisateur #{email} absent"
    end

    def self.actor(email : String, permissions : Array(String)) : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(user_id(email), permissions, level: 3)
    end

    # Comptable : toute l'extension et les droits du cœur qu'elle emploie.
    def self.accountant : Partiduo::Api::Actor
      actor("alice@example.com", [Api::READ, Api::WRITE, Api::ADMIN] + CORE_PERMISSIONS)
    end

    def self.reader : Partiduo::Api::Actor
      actor("bruno@example.com", [Api::READ, "accounting.ledger.read", "accounting.account.read"])
    end

    def self.fiscal_year(year : Int32) : Partiduo::Api::Core::FiscalYearView
      Partiduo::Api::Core.fiscal_years(system).find(&.year.==(year)) || raise "exercice #{year} absent"
    end

    def self.account(number : String, label : String = "Compte #{number}") : Nil
      return if Amortis::Accounts.exists?(number)
      Acc.create_account(system, Acc::AccountInput.new(number: number, label: label)).value!
    end

    # Immobilisation de `gross` acquise et mise en service le `day`.
    def self.asset(label : String, account : String, gross : String, day : String, months : Int32 = 60,
                   method : String = "linear", fiscal_method : String = "same", fiscal_months : Int32? = nil,
                   parent_id : Int64? = nil, service : String? = day, residual : String = "0") : Api::AssetView
      account(account)
      input = Api::AssetInput.new(label: label, asset_account: account, acquired_on: date(day), gross_value: d(gross),
        in_service_on: service.try { |text| date(text) }, method: method, life_months: months,
        fiscal_method: fiscal_method, fiscal_life_months: fiscal_months, parent_id: parent_id, residual_value: d(residual))
      result = Api.create_asset(accountant, input)
      raise "immobilisation refusée : #{result.error_keys.join(", ")}" if result.failure?
      result.value!
    end

    def self.misc_ledger : Acc::LedgerView
      Acc.ledger_by_code(system, "O01")
    end

    # Lignes d'une écriture : `{compte, sens, montant}` triés.
    def self.lines(entry_id : Int64) : Array({String, String, String})
      Acc.entry(system, entry_id).lines.map { |line| {line.account_number, line.side.code, line.amount.to_s} }.sort!
    end
  end
end
