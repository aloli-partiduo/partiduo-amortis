# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Acquisitions à inscrire (D-AMO-004, D-AMO-019) : lignes d'écritures des
  # exercices ouverts au débit d'un compte d'immobilisation, qu'aucune
  # immobilisation ne cite. Lues par le contrat de la Comptabilité avec les
  # droits de l'acteur (journaux visibles). Interne.
  #
  # * La liste parcourt les écritures des exercices ouverts qui touchent un
  #   compte de la classe 2, page après page (`page_size` par lecture), sans
  #   plafond ;
  # * une ligne se relit par son identifiant (`Accounting.entry_line`,
  #   D-AMD-010 du cœur) pour la rattacher à une immobilisation, sans
  #   relire les écritures.
  module Candidates
    alias Acc = Partiduo::Api::Accounting
    alias Api = Amortis::Api

    # Écritures lues par page (plafond d'une lecture du contrat) ; réglable
    # par les specs.
    class_property page_size : Int32 = 500

    def self.list(actor : Partiduo::Api::Actor) : Array(Api::CandidateView)
      regime = Settings.regime
      from = open_from || return [] of Api::CandidateView
      used = used_lines
      candidates = [] of Api::CandidateView
      offset = 0
      loop do
        query = Acc::EntryQuery.new(account: "2", account_prefix: true, date_from: from, include_cancelled: false,
          offset: offset, limit: page_size)
        entries = Acc.entries(actor, query)
        entries.each do |entry|
          next if entry.reversal?
          found = entry.lines.select { |line| acquisition?(regime, line) && !used.includes?(line.id) }
          candidates.concat(found.map { |line| view(entry, line) })
        end
        break if entries.size < page_size
        offset += page_size
      end
      candidates
    rescue Partiduo::Api::AccessDenied
      [] of Api::CandidateView
    end

    # Acquisition à inscrire de la ligne `line_id`, relue par son
    # identifiant ; `nil` si elle n'est pas lisible par l'acteur, déjà
    # citée, annulée, hors des exercices ouverts ou pas au débit d'un compte
    # d'immobilisation.
    def self.find(actor : Partiduo::Api::Actor, line_id : Int64) : Api::CandidateView?
      return if used_lines.includes?(line_id)
      line = Acc.entry_line(actor, line_id)
      return unless acquisition?(Settings.regime, line)
      entry = Acc.entry(actor, line.entry_id || return)
      from = open_from || return
      return if entry.cancelled? || entry.reversal? || entry.date < from
      view(entry, line)
    rescue Partiduo::Api::NotFound | Partiduo::Api::AccessDenied
      nil
    end

    # Début du plus ancien exercice ouvert ; `nil` s'il n'y en a pas.
    private def self.open_from : Time?
      Partiduo::Api::Core.fiscal_years(Records.system).reject(&.closed?).compact_map(&.starts_on).min?
    end

    private def self.used_lines : Set(Int64)
      Asset.all.pluck(:entry_line_id).compact_map(&.first.try(&.as(Int64))).to_set
    end

    private def self.acquisition?(regime : String, line : Acc::EntryLineView) : Bool
      line.side.debit? && Accounts.asset_account?(regime, line.account_number)
    end

    private def self.view(entry : Acc::EntryView, line : Acc::EntryLineView) : Api::CandidateView
      Api::CandidateView.new(entry_id: entry.id, line_id: line.id, date: entry.date, ledger_code: entry.ledger_code,
        receipt: entry.receipt, label: line.label.presence || entry.label, account: line.account_number,
        account_label: line.account_label, amount: line.amount)
    end
  end
end
