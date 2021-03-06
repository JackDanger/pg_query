class PgQuery
  # Returns a list of columns that the query filters by - this excludes the
  # target list, but includes things like JOIN condition and WHERE clause.
  #
  # Note: This also traverses into sub-selects.
  def filter_columns # rubocop:disable Metrics/CyclomaticComplexity
    load_tables_and_aliases! if @aliases.nil?

    # Get condition items from the parsetree
    statements = @parsetree.dup
    condition_items = []
    filter_columns = []
    loop do
      statement = statements.shift
      if statement
        if statement['SELECT']
          if statement['SELECT']['op'] == 0
            if statement['SELECT']['fromClause']
              # FROM subselects
              statement['SELECT']['fromClause'].each do |item|
                next unless item['RANGESUBSELECT']
                statements << item['RANGESUBSELECT']['subquery']
              end

              # JOIN ON conditions
              condition_items += conditions_from_join_clauses(statement['SELECT']['fromClause'])
            end

            # WHERE clause
            condition_items << statement['SELECT']['whereClause'] if statement['SELECT']['whereClause']

            # CTEs
            if statement['SELECT']['withClause']
              statement['SELECT']['withClause']['WITHCLAUSE']['ctes'].each do |item|
                statements << item['COMMONTABLEEXPR']['ctequery'] if item['COMMONTABLEEXPR']
              end
            end
          elsif statement['SELECT']['op'] == 1
            statements << statement['SELECT']['larg'] if statement['SELECT']['larg']
            statements << statement['SELECT']['rarg'] if statement['SELECT']['rarg']
          end
        elsif statement['UPDATE']
          condition_items << statement['UPDATE']['whereClause'] if statement['UPDATE']['whereClause']
        elsif statement['DELETE FROM']
          condition_items << statement['DELETE FROM']['whereClause'] if statement['DELETE FROM']['whereClause']
        end
      end

      # Process both JOIN and WHERE conditions here
      next_item = condition_items.shift
      if next_item
        if next_item.keys[0].start_with?('AEXPR') || next_item['ANY']
          %w(lexpr rexpr).each do |side|
            expr = next_item.values[0][side]
            next unless expr && expr.is_a?(Hash)
            condition_items << expr
          end
        elsif next_item['ROW']
          condition_items += next_item['ROW']['args']
        elsif next_item['COLUMNREF']
          column, table = next_item['COLUMNREF']['fields'].reverse
          filter_columns << [@aliases[table] || table, column]
        elsif next_item['NULLTEST']
          condition_items << next_item['NULLTEST']['arg']
        elsif next_item['FUNCCALL']
          # FIXME: This should actually be extracted as a funccall and be compared with those indices
          condition_items += next_item['FUNCCALL']['args'] if next_item['FUNCCALL']['args']
        elsif next_item['SUBLINK']
          condition_items << next_item['SUBLINK']['testexpr']
          statements << next_item['SUBLINK']['subselect']
        end
      end

      break if statements.empty? && condition_items.empty?
    end

    filter_columns.uniq
  end

  protected

  def conditions_from_join_clauses(from_clause)
    condition_items = []
    from_clause.each do |item|
      next unless item['JOINEXPR']

      joinexpr_items = [item['JOINEXPR']]
      loop do
        next_item = joinexpr_items.shift
        break unless next_item
        condition_items << next_item['quals'] if next_item['quals']
        %w(larg rarg).each do |side|
          next unless next_item[side]['JOINEXPR']
          joinexpr_items << next_item[side]['JOINEXPR']
        end
      end
    end
    condition_items
  end
end
