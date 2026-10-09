# SPDX-License-Identifier: AGPL-3.0-or-later

module Amortis
  # Exercice d'un plan d'amortissement : celui d'un exercice du socle
  # (`fiscal_year_id`), ou prolongé de douze mois en douze mois avant le
  # premier et après le dernier, pour les plans qui les dépassent
  # (D-AMO-005). Dates à minuit UTC, fin comprise.
  record Exercise, starts_on : Time, ends_on : Time, fiscal_year_id : Int64? = nil, label : String = "" do
    def includes?(day : Time) : Bool
      starts_on <= day <= ends_on
    end

    def days : Int32
      ((ends_on - starts_on).days + 1).to_i32
    end

    # Durée en années : mois entiers ÷ 12 quand l'exercice commence le
    # premier d'un mois et finit la veille d'un premier ; sinon jours ÷ 365.
    def years : BigDecimal
      after = ends_on + 1.day
      if starts_on.day == 1 && after.day == 1
        BigDecimal.new((after.year - starts_on.year) * 12 + after.month - starts_on.month) / 12
      else
        BigDecimal.new(days) / 365
      end
    end

    def key : String
      starts_on.to_s("%Y-%m-%d")
    end

    def display_label : String
      label.empty? ? ends_on.year.to_s : label
    end
  end

  # Calendrier des exercices (interne).
  module Calendar
    # Exercices qui couvrent `from` à `to` : ceux du socle (`known` :
    # début, fin, identifiant, libellé), les trous comblés par un exercice,
    # puis douze mois de plus en plus avant et après. Sans exercice connu :
    # années civiles.
    def self.exercises(known : Array(Exercise), from : Time, to : Time) : Array(Exercise)
      list = known.sort_by(&.starts_on)
      list = [Exercise.new(Time.utc(from.year, 1, 1), Time.utc(from.year, 12, 31))] if list.empty?
      filled = [] of Exercise
      list.each do |item|
        if last = filled.last?
          next if item.starts_on <= last.ends_on
          filled << Exercise.new(last.ends_on + 1.day, item.starts_on - 1.day) if item.starts_on > last.ends_on + 1.day
        end
        filled << item
      end
      while filled.first.starts_on > from
        first = filled.first
        filled.unshift(Exercise.new(first.starts_on.shift(months: -12), first.starts_on - 1.day))
      end
      while filled.last.ends_on < to
        last = filled.last
        start = last.ends_on + 1.day
        filled << Exercise.new(start, start.shift(months: 12) - 1.day)
      end
      filled
    end

    # Exercice qui contient le jour, parmi `list`.
    def self.find(list : Array(Exercise), day : Time) : Exercise?
      list.find(&.includes?(day))
    end
  end
end
