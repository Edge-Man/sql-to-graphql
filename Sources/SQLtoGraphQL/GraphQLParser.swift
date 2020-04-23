//
//  File.swift
//  
//
//  Created by Andre Carrera on 4/16/20.
//

import Foundation

/// Parses all the examples belonging to a single database and schema.
/// Strategy: Create different GraphqlQueries and combine them once we know everything we need.
class DatabaseExamplesParser: Codable {
    let schema: BaseSchema
    let examples: [DatasetExample]
    let database: Database
    init(schema: BaseSchema, examples: [DatasetExample], database: Database) {
        self.schema = schema
        self.examples = examples
        self.database = database
    }
    
    public func parse() -> (successfulExamples :[GraphQLDatasetExample], failedExamples: [DatasetExample]) {
        let (successfulExamples, failedExamples) =  self.examples.reduce(([],[])) { (previousResult, currentExample) -> ([GraphQLDatasetExample], [DatasetExample]) in
            let (successful, failed) = previousResult
            do {
                let processedQuery = try self.processQuery(sql: currentExample.sql).encode()
                let processedExample = GraphQLDatasetExample(
                    schemaId: currentExample.dbID,
                    question: currentExample.question,
                    questionTokens:
                    currentExample.questionToks,
                    query: processedQuery)
                return (successful + [processedExample], failed)
            } catch {
                print(error)
                // TODO return error?
                return (successful, failed + [currentExample])
            }
        }
        return (successfulExamples, failedExamples)
    }
    
    private func processQuery(sql: SQL) throws -> GraphQLQuery {
        let rawQueryGroup = try self.parse(sql: sql)
        return self.orderQuery(group: rawQueryGroup)
    }
    
    private func orderQuery(group: RawGraphQLQueryGroup) -> GraphQLQuery {
        // TODO order query from info in raw query
        // this could also be done in the init for GraphQLQuery
        // I will be getting all the query tables
        // with all thier fields
        // nested in aggregate as needed
        // and all of the where arguments
        // as well as the orderby arguments
        // and limit arguments
        
        // Here:
        // attempt to combine all of the queries into one query
        // verifying that the schema allows each nested query.
        // and fitting arguments into the nested order as needed.
        
        // TODO:
        // [] decide if I'm transfering away from RawGraphQLQuery or not
        // [x] handle isDistinct
        //   -> will have to add distinct_on to every other nested query as an arugment
        //   -> double check these as they can possibly take a long time for the server to query.
        
        
        // asumption: any cases with isDistinct are only on one column from one table. based on `parseSelect`
        
        // reduce selects into a nested query
        // aggregate queries are first
        let queries = group.queries.reduce([], { $1.hasAggregates ? [$1] + $0 : $0 + [$1] }) // should `*`s go first as well?
        let firstQuery = queries.first!
        if firstQuery.table.name != "*" {
            firstQuery.setNameFrom(schema: self.schema)
        }
        // prepare to handle any table.
        let hasAnyTable = queries.contains(where: {$0.table.name == "*"})
        let queriesWithTables = queries.filter{ $0.table.name != "*" }
        if hasAnyTable && queries.count == 1 {
            firstQuery.table = group.fromTableQueries.first!.table
            firstQuery.setNameFrom(schema: self.schema)
        } else if hasAnyTable && group.fromTableQueries.count == 1 {
            queries.forEach{ query in
                query.table = group.fromTableQueries.first!.table
                query.setNameFrom(schema: self.schema)
            }
        } else if hasAnyTable && queriesWithTables.count == 1, let queryWithTable = queriesWithTables.first {
            queries.forEach{ query in
                query.table = queryWithTable.table
                query.setNameFrom(schema: self.schema)
            }
        } else if hasAnyTable {
            fatalError("has any table (*) that isn't handled")
        }
        
        let rootQuery = queries
            .dropFirst()
            .reduce(firstQuery, { self.nestQueries(into: $0, currentQuery: $1) }) // TODO check that every query is used.
        // TODO
        // [] handle cases where rootTable is `*`
        //    can happen on aggregate or on any
        //    but I don't have access to the name? nope
        //    I'll have get it from FROM
        // [] convert all fields to their correct name.
        // [] handle when a field is named "*"
        
        
        
        
        // reduce arguments into the root query
        // add other arguments as well.
        return GraphQLQuery(fieldName: "")
    }
    
    // i could nest into a GraphQLQuery as well
    private func nestQueries(into previousResult: RawGraphQLQuery, currentQuery: RawGraphQLQuery) -> RawGraphQLQuery {
        // search previousResult to place current into it.
        // at most 3 levels deep
        // using recurssion
        // escape condition is that previousResult query has currentQuery as a child
        // returns previousResult with currentQuery added to child Query.
        let parentName = previousResult.name!
        if previousResult.hasAggregates,
            let nodesQuery = previousResult.queries.first,
            let childName = self.getChildQueryName(child: currentQuery, of: parentName) {
            // TODO name nodesQuery here or in select
            // return new result
            currentQuery.name = childName
            previousResult.queries.first!.queries = nodesQuery.queries + [currentQuery]
            return previousResult
        } else if previousResult.hasAggregates {// if is aggregate but child isn't found
            previousResult.queries.first!.queries = previousResult.queries.first!.queries.map{ self.nestQueries(into: $0, currentQuery: currentQuery)  }
            return previousResult
        } else if let childName = self.getChildQueryName(child: currentQuery, of: parentName) {
            currentQuery.name = childName
            previousResult.queries = previousResult.queries + [currentQuery]
            return previousResult
        } else { // if not aggregate and child isn't found.
            // go through each of the queries
            // pass into this same function
            previousResult.queries = previousResult.queries.map{ self.nestQueries(into: $0, currentQuery: currentQuery) }
            return previousResult
        }
        // TODO could make another else and try make current, the parent.
    }
    
    func getChildQueryName(child: RawGraphQLQuery, of parentName: String ) -> String? {
        let parentName = parentName.lowercased()
        let queryType = schema.schema.types.first(where: {$0.name.lowercased() == parentName})!
        if let childType = queryType.fields?.first(where: { $0.name.lowercased() == child.table.name.lowercased() }) { // this isn't correct yet.
            // TODO: 
            // it needs to be a neseted query name for they right type. (there might be multiple)
            // any children to this new node need a reference to this new name ( there is only 30 cases of this, so I could catch them manually ).
            return childType.name + (child.hasAggregates ? "_aggregate" : "")
        } else {
            return nil
        }
    }
    
    private func parse(sql: SQL) throws -> RawGraphQLQueryGroup {
        // FROM CLAUSE
        let fromQueryTables = try self.parseFrom(sql.from)
        // WHERE CLAUSE
        let whereReducedArgument = try self.parseWhereSQL(sql.sqlWhere)
        // GROUPBY & HAVING CLAUSE
        if !sql.groupBy.isEmpty { // 2169 cases
            throw ProcessingError.unsupportedGroupBy
        }
        // SELECT clause (distinct)
        // I could get rid of the fromQueryTables. Since all the info is in the subsequent queries.
        let (queriesWithFields, isDistinct) = try self.parseSelect(sql.select.toStruct())
        
        // ORDER BY clause
        let orderByArgument = try self.parseOrderBy(sql.orderBy.toStruct())
        // LIMIT clause
        let limitArgument = sql.limit.map{RawGraphQLArgument(name: .and, value: .integer($0)) }
        // except (should only work if the tables being queried are the same)
        if sql.except != nil { // 230 cases
            throw ProcessingError.unsupportedExcept
        }
        // intersect ?
        if sql.intersect != nil { // 267 cases
            throw ProcessingError.unsupportedIntersect
        }
        // union (just combine this result with the currect values)
        if sql.union != nil { // 64 cases
            throw ProcessingError.unsupportedUnion
        }
        //TODO fix return value
        return RawGraphQLQueryGroup(queries: queriesWithFields, fromTableQueries: fromQueryTables, whereArgument: whereReducedArgument, orderByArgument: orderByArgument, limitArgument: limitArgument, isDistinct: isDistinct)
    }
    
    /// returns a `RawGraphQLArgument?` holding the orderBy argument
    func parseOrderBy(_ orderBy: OrderByStruct?) throws -> RawGraphQLArgument? {
        // assumption all aruments will follow the same direction.
        guard let orderBy = orderBy else { return nil }
        
        let orderBys = try orderBy.valueUnits.map { valueUnit -> RawGraphQLArgument in
            guard valueUnit.unitOperation == .none else {
                // example
                // SELECT T1.name FROM accounts AS T1 JOIN checking AS T2 ON T1.custid  =  T2.custid JOIN savings AS T3 ON T1.custid  =  T3.custid ORDER BY T2.balance + T3.balance LIMIT 1
                throw ProcessingError.unsupportedUnitOperation // These aren't possible to write in current form of hasura
            }
            assert(valueUnit.columnUnit1.aggregateOperation == .none, "No aggregate operations when there are no GroupBys.")
            let column = self.database.columns[valueUnit.columnUnit1.columnId]  //
            return RawGraphQLArgument(name: .column(column), value: .namedValue(orderBy.direction.rawValue))
        }
        
        return RawGraphQLArgument(name: .orderBy, value: .arguments(orderBys))
    }
    
    /// matches each select column to it's corresponding query, updates queries to aggregates as needed.
    /// includes a new Query for the table`*` if and only if there is an aggregate field.
    /// and returns a distinct argument
    func parseSelect(_ select: SelectStruct) throws -> (queries: [RawGraphQLQuery], isDistinct: Bool)  {
        // group fields by table name.
        let anyTable = DatabaseTable(index: -1, name: "*", columns: [])
        let tableToSelectField = Dictionary(grouping: select.selectStatements, by: { selectField -> DatabaseTable in
            let columnId = selectField.valueUnit.columnUnit1.columnId
            if columnId == 0 {
                return anyTable
            }
            let column = self.database.columns[columnId]
            return self.database.tables[column.tableIndex]
        })
        
        // 89 cases of distinct with multiple columns on the same table
        // These should be adaptable (remove unique from question or query)
        guard !select.isDistinct || tableToSelectField.values.filter({ $0.count > 1}).isEmpty else {
            throw ProcessingError.unsupportedDistinctOnMultipleColumns
        }
        
        // 34 cases of distinct with multiple tables
        // These could be adaptable but these queries take a long time
        guard !select.isDistinct || tableToSelectField.keys.count == 1 else {
            throw ProcessingError.unsupportedDistinctOnMultipleTables
        }
        
        // if fields need any table
        // BUG in their parsing. some tables aren't in from conds or tableUnits.
        //        assert(!fields.keys.map{tables[$0]}.contains(where: { $0 == nil}), "all fields don't match up to a table.")
        
        let queriesWithFields = try self.match(fields: tableToSelectField)
        // some won't have a table.
        
        // There are cases that query including a math operation (unitOperation)
        // There are only 13 cases of this.
        // example:
        // SELECT population / area FROM state WHERE state_name  =  \"pennsylvania\";
        
        // return isDistinct argument.
        return (queriesWithFields, select.isDistinct)
    }
    
    /// matches fields to their tables.
    /// returns each Query holding fields. Query is nested if an aggregate is needed.
    /// includes a new Query for the table`*` if and only if there is an aggregate field.
    func match(fields: [DatabaseTable: [SelectField]]) throws  -> [RawGraphQLQuery]  {
        
        //        assert(!fields.keys.map{tables[$0]}.contains(where: { $0 == nil}), "all fields don't match up to a table.")
        return try fields.map { (table, matchingFields) in
            // if a query table has no matching fields, just return it as is.
            // groups by .aggregateOpperation throws if operation isn't supported
            let (matchingAggregates, matchingColumnFields) = try matchingFields.reduce(([],[])) { (resultPair, field) -> ([SelectField],[SelectField]) in
                // this guard could be moved up a level.
                guard field.valueUnit.unitOperation == .none else { throw ProcessingError.unsupportedUnitOperation }
                let (aggregates, columns) = resultPair
                if field.aggregateOpperation == .none {
                    return (aggregates, columns + [field])
                } else {
                    return (aggregates + [field], columns)
                }
            }
            let columnFields = matchingColumnFields.map { field -> RawGraphQLField in
                let columnId = field.valueUnit.columnUnit1.columnId
                let column = self.database.columns[columnId]
                assert(columnId != -1)
                assert(field.valueUnit.columnUnit2 == nil)
                assert(field.valueUnit.unitOperation == .none)
                assert(!field.valueUnit.columnUnit1.isDistinct)
                return RawGraphQLField(name: .field(column.columnName), column: column )
            }
            
            let queryWithFields = RawGraphQLQuery(table: table, fields: columnFields)
            
            if matchingAggregates.isEmpty {
                return queryWithFields
            } else {
                let aggregateFields = matchingAggregates.map { field -> RawGraphQLField in
                    let columnId = field.valueUnit.columnUnit1.columnId
                    let column = columnId != -1 ? self.database.columns[columnId] : DatabaseColumn(columnName: "*", tableIndex: -1, tableName: "*")
                    assert(!field.valueUnit.columnUnit1.isDistinct || field.aggregateOpperation == .count || field.aggregateOpperation == .max || field.aggregateOpperation == .min)
                    assert(field.valueUnit.columnUnit2 == nil)
                    assert(field.valueUnit.unitOperation == .none)
                    // distinct only matters for .count
                    let hasDistinctArgument = field.aggregateOpperation == .count && field.valueUnit.columnUnit1.isDistinct
                    let arguments = hasDistinctArgument ? [RawGraphQLArgument(name: .distinct, value: .bool(field.valueUnit.columnUnit1.isDistinct))] : []
                    return RawGraphQLField(name: .aggregate(field.aggregateOpperation), column: column, arguments: arguments)
                }
                let aggregatesQuery = RawGraphQLQuery(table: table, fields: aggregateFields)
                // TODO: queryWithFields will become `nodes`
                return RawGraphQLQuery(table: table, queries: [queryWithFields, aggregatesQuery], hasAggregates: true)
            }
        }
    }
    
    
    /// returns all tables to be joined in a list GraphQLQuery  (not matching the schema yet, and only hodling the table name)
    func parseFrom(_ from: SQLFrom) throws -> [RawGraphQLQuery] {
        let tableQueries = try from.allTableUnits.compactMap(self.tableUnitToQuery(unit:))
        
        assert(from.conds.count % 2 == 1 || from.conds.isEmpty, "From conditions should be odd or 0.")
        // 0 example: SELECT release_year FROM movie WHERE title  =  \"The Imitation Game\";
        
        // There are only 42 examples that have more than one condition.
        // of those there are either 3 or 5 conditions.
        
        // all conditions are joins on foreign keys.
        // can check using:
        //        if !from.conds.isEmpty, let firstCondition = from.condition(at: 0) {
        //            print("working so far")
        //        }
        // all conditions use `And`
        // check using.
        //        let containsOR = from.conds.contains(where:  { if case .enumeration(.or) = $0 { return true } else { return false } })
        //        assert(!containsOR)
        //looks like this just uses multiple foreign keys to make a relation
        // we already have this relation knowledge
        let condsTables = from.conds.compactMap{ condition -> RawGraphQLQuery? in
            if case .conditionUnit(let unitCondition) = condition {
                let unit = unitCondition.toStruct()
                assert(!unit.notOperation, "Not operation should not be found on condition")
                assert(unit.operation == .equals, "Only equals operation allowed in from.")
                assert(unit.val2 == nil, "Multiple values not allowed on single condition.")
                assert(unit.val1.aggregateOperation == .none, "no aggregate allowed")
                let column = self.database.columns[unit.val1.columnId]
                let table = self.database.tables[column.tableIndex]
                return RawGraphQLQuery(table: table)
            } else {
                return nil
            }
        }
        
        // TODO conditions! I need to get all conditions.
        // they are all equal. but how many are and / or?
        
        
        return tableQueries + condsTables
    }
    
    /// parse the WHERE clause using extracted tables.
    func parseWhereSQL(_ whereConditions: [SQLWhere]) throws -> RawGraphQLArgument? {
        // find which filter arguments to use on which rawQueries
        guard !whereConditions.isEmpty,
            let firstWhere = whereConditions.first,
            case .whereCondition(let firstCondition) = firstWhere else {
                return nil
        }
        // there are more than 1300 examples with 3, 5, and 7 where conditions.
        
        let firstWhereCondition = firstCondition.toStruct()
        let firstArgument = try self.getArgument(from: firstWhereCondition)
        
        let reducedArgument = try  whereConditions.dropFirst().reduce(firstArgument, self.storeArguments(result:currentWhere:))
        
        return reducedArgument
    }
    
    /// Called to reduce `SQLWhere`s into a single `RawGraphQLArgument`
    func storeArguments(result: RawGraphQLArgument, currentWhere: SQLWhere) throws -> RawGraphQLArgument{
        // result name can be either 'and' 'or', 'column'
        // currentWhere can be either 'and' 'or', (condittion -> 'column')
        // there are 9 options, all of them are possible, except column then column
        // I could simplify but I'd rathe be explicit.
        
        // compare previous result and current where
        // might need to start the search here
        if case .and = result.name, case .whereCondition(let whereCondition) = currentWhere,
            case .arguments(let arguments) = result.value {
            let condition = whereCondition.toStruct()
            let argument = try getArgument(from: condition)
            
            return RawGraphQLArgument(name: result.name, value: .arguments(arguments + [argument]))
            
        } else if case .and = result.name, case .enumeration(.and) = currentWhere {
            // since it's already in an `and` do nothing.
            return result
        } else if case .and = result.name, case .enumeration(.or) = currentWhere {
            return RawGraphQLArgument(name: .or, value: .arguments([result]))
        } else if case .or = result.name, case .whereCondition(let whereCondition) = currentWhere,
            case .arguments(let arguments) = result.value, let lastArgument = arguments.last {
            let condition = whereCondition.toStruct()
            let currentArgument = try getArgument(from: condition)
            
            var newArgumentValues: [RawGraphQLArgument]
            if case .and = lastArgument.name, case .arguments(let nestedAndArguments) = lastArgument.value,
                nestedAndArguments.count == 1, let firstNestedAndArgument = nestedAndArguments.first {
                let newNestedAndArguments: [RawGraphQLArgument] = [firstNestedAndArgument, currentArgument ]
                newArgumentValues = arguments.dropLast() + [RawGraphQLArgument(name: .and, value: .arguments(newNestedAndArguments))]
            } else {
                newArgumentValues = arguments + [currentArgument]
            }
            
            return RawGraphQLArgument(name: result.name, value: .arguments(newArgumentValues))
        } else if case .or = result.name, case .enumeration(.and) = currentWhere,
            case .arguments(let arguments) = result.value, let lastArgument = arguments.last,
            case .column(_) = lastArgument.name {// should be a column
            // take the column out of the `or` and put it into the `and`
            let newAndArgument = RawGraphQLArgument(name: .and, value: .arguments([lastArgument]))
            return RawGraphQLArgument(name: .or, value: .arguments(arguments.dropLast() + [newAndArgument]))
        } else if case .or = result.name, case .enumeration(.or) = currentWhere {
            // since it's already in an `or` do nothing
            return result
        } else if case .column(_) = result.name, case .enumeration(.and) = currentWhere {
            return RawGraphQLArgument(name: .and, value: .arguments([result]))
        } else if case .column(_) = result.name, case .enumeration(.or) = currentWhere {
            return RawGraphQLArgument(name: .or, value: .arguments([result]))
        } // not possible to have a column then another column.
        else {
            fatalError("Conditions order is wrong. ")
        }
    }
    
    func tableUnitToQuery(unit: TableUnit) throws -> RawGraphQLQuery? {
        switch unit {
        case .nestedSQL(_):
            // this only occurs 13 times.
            // example:
            // SELECT count(*) FROM
            // ( SELECT * FROM postseason AS T1 JOIN team AS T2 ON T1.team_id_winner  =  T2.team_id_br WHERE T2.name  =  \'Boston Red Stockings\' UNION SELECT * FROM postseason AS T1 JOIN team AS T2 ON T1.team_id_loser  =  T2.team_id_br WHERE T2.name  =  \'Boston Red Stockings\' )
            // TODO:
            // [x]  decide
            // return arguments found in here as well.
            // just throw
            
            // These are possible to do manually.
            
            //            print("Nested sql in from.")
            //            return self.parse(sql: sql)
            throw ProcessingError.unsupportedNestedSQLFrom
        case .tableIndex(let tableIndex):
            return RawGraphQLQuery(table: self.database.tables[tableIndex])
        default:
            return nil
        }
    }
    
    /// Gets a RawGraphQLArgument holding the column and it's conditions
    func getArgument(from condition: WhereConditionStruct) throws -> RawGraphQLArgument {
        // Where
        guard condition.valueUnit.unitOperation == .none else { // 6 occurances of this
            throw ProcessingError.unsupportedUnitOperation
        }
        
        let value = try self.getArugmentValue(from: condition.val1)
        
        let column = self.database.columns[condition.valueUnit.columnUnit1.columnId]
        // should I store the column name with it's table?
        // TODO put operation inside of argument!!!
        return RawGraphQLArgument(name: .column(column), value: value, not: condition.notOperation)
    }
    
    func getArugmentValue(from conditionType: WhereConditionStruct.ValueType) throws -> RawGraphQLArgument.RawGraphQLArgumentValue {
        switch conditionType {
        case .double(let val):
            return .double(val)
        case .integer(let val):
            return .integer(val)
        case .string(let val):
            return .string(val)
        case .sql(_):
            // There are 1039 occurances of this.
            // example:
            // SELECT t2.house_number  ,  t1.name FROM restaurant AS t1 JOIN LOCATION AS t2 ON t1.id  =  t2.restaurant_id
            // WHERE t2.city_name  =  \"san francisco\"
            // AND t1.food_type  =  \"french\"
            // AND t1.rating  =  ( SELECT MAX ( t1.rating ) FROM restaurant AS t1 JOIN LOCATION AS t2 ON t1.id  =  t2.restaurant_id WHERE t2.city_name  =  \"san francisco\" AND t1.food_type  =  \"french\" )
            
            // This doesn't look possible without creating custom functions in hasura.
            // I can't filter based off of the the result of another query in hasura as it is.
            //            print("nested sql conditions not supported in hasura without creating a function.")
            throw ProcessingError.unsupportedNestedSQL
            //            let arguments = self.parseWhereSQL(val).map{[$0]} ?? []
        //            return .arguments([])
        case .columnUnit(_):
            // There are 27 occurances of this. none of them happen inside a nested sql argument ^
            throw ProcessingError.unsupportedColumnUnitForWhere
            //            print(".columnUnit not supported in hasura without creating a function.")
            //            return .arguments([])
            // These queries aren't possible in graphql.
            // For any rating where the name of reviewer is the same as the director of the movie, return the reviewer name, movie title, and number of stars.
            // SELECT DISTINCT T3.name ,  T2.title ,  T1.stars FROM Rating AS T1 JOIN Movie AS T2 ON T1.mID  =  T2.mID JOIN Reviewer AS T3 ON T1.rID  =  T3.rID WHERE T2.director  =  T3.name
        }
    }
    
}

/// helpful functions and verifiy functions.
extension DatabaseExamplesParser {
    /// verify that this operation only checks the id of the values in a join.
    func isForeignKeyJoin(_ condition: ConditionUnitStruct, queries: [RawGraphQLQuery]) -> Bool {
        let column1 = self.database.columns[condition.valueUnit.columnUnit1.columnId]
        let column2 = self.database.columns[condition.val1.columnId]
        
        let isIDJoin = column1.columnName.lowercased().contains("id") && column2.columnName.lowercased().contains("id")
        
        let isOtherForeignKeyJoin = column1.columnName.lowercased() == column2.columnName.lowercased()
        // note: some foreign key names don't match but are still keys
        
        //        if isOtherForeignKeyJoin {
        //            print("\(column1.columnName) == \(column2.columnName)")
        //        }
        if !isIDJoin && !isOtherForeignKeyJoin {
            print("\(column1.columnName) != \(column2.columnName)")
        }
        //            if condition.operation != .equals {
        //                print(condition.operation)
        //            }
        
        
        // All condition operations are .equals!
        // All operations use a forein ID
        
        
        return condition.operation == .equals && (isIDJoin || isOtherForeignKeyJoin)
    }
}


enum ProcessingError: Error {
    case unsupportedUnitOperation
    case unsupportedNestedSQL
    case unsupportedGroupBy
    case unsupportedExcept
    case unsupportedIntersect
    case unsupportedUnion
    case unsupportedColumnUnitForWhere
    case unsupportedNestedSQLFrom
    case unsupportedDistinctOnMultipleColumns
    case unsupportedDistinctOnMultipleTables
    case nameFromTypesError
}