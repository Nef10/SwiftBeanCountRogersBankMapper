import Foundation
import RogersBankDownloader
import SwiftBeanCountModel
import SwiftBeanCountParserUtils

/// Mapper to map downloaded accounts and activities to BeanCoutModel objects
public struct SwiftBeanCountRogersBankMapper {

    private static let dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return dateFormatter
    }()

    /// Account name to which the expenses are posted
    public let expenseAccountName = try! AccountName("Expenses:TODO") // swiftlint:disable:this force_try

    private let ledger: Ledger

    /// Creates a mapper
    /// - Parameter ledger: Ledger which will be used to look up account names
    public init(ledger: Ledger) {
        self.ledger = ledger
    }

    /// Maps an account to a balance assertion
    /// - Parameter account: account to map
    /// - Throws: RogersBankMappingError if no matching account was found
    /// - Returns: balance assertion with the current balance form the credit card account
    public func mapAccountToBalance(account: RogersBankDownloader.Account) throws -> Balance {
        let (number, decimalDigits) = account.currentBalance.value.amountDecimal()
        let amount = Amount(number: -number, commoditySymbol: account.currentBalance.currency, decimalDigits: decimalDigits)
        let accountName = try ledgerAccountName(lastFour: account.customer.cardLast4)
        return Balance(date: Date(), accountName: accountName, amount: amount)
    }

    /// Maps an activity to a transaction
    /// - Parameters
    ///   - activity: Activity to map
    ///   - date: Date to use for the transaction
    ///   - referenceNumber: Reference Number to add to the meta data
    /// - Throws: RogersBankMappingError
    /// - Returns: Transactions
    private func mapActivity(_ activity: Activity, date: Date, referenceNumber: String) throws -> Transaction {
        let accountName = try ledgerAccountName(lastFour: String(activity.cardNumber.suffix(4)))
        let metaData = TransactionMetaData(date: date, narration: activity.merchant.name, metaData: [MetaDataKeys.activityId: referenceNumber])
        let (number, decimalDigits) = activity.amount.value.amountDecimal()
        let amount = Amount(number: number, commoditySymbol: activity.amount.currency, decimalDigits: decimalDigits)
        let negatedAmount = Amount(number: -number, commoditySymbol: activity.amount.currency, decimalDigits: decimalDigits)
        var postings = [Posting(accountName: accountName, amount: negatedAmount)]
        if let foreign = activity.foreign {
            let (number, decimalDigits) = foreign.originalAmount.value.amountDecimal()
            let foreignAmount = Amount(number: number, commoditySymbol: foreign.originalAmount.currency, decimalDigits: decimalDigits)
            postings.append(Posting(accountName: expenseAccountName, amount: foreignAmount, price: amount))
        } else {
            postings.append(Posting(accountName: expenseAccountName, amount: amount))
        }
        return Transaction(metaData: metaData, postings: postings)
    }

    /// Maps activities to transactions
    /// - Parameter activities: Activities to map
    /// - Throws: RogersBankMappingError
    /// - Returns: Transactions
    public func mapActivitiesToTransactions(activities: [Activity]) throws -> [Transaction] {
        var transactions = [Transaction]()
        for activity in activities where activity.activityStatus == .approved && activity.activityType == .transaction {
            guard let postedDate = activity.postedDate else {
                throw RogersBankMappingError.missingActivityData(activity: activity, key: "postedDate")
            }
            let referenceNumber: String
            if activity.activityCategory == .payment {
                referenceNumber = "payment-\(Self.dateFormatter.string(from: postedDate))"
            } else if activity.activityCategory == .overlimitFee {
                referenceNumber = "overlimit-fee-\(Self.dateFormatter.string(from: postedDate))"
            } else {
                guard let number = activity.referenceNumber else {
                    throw RogersBankMappingError.missingActivityData(activity: activity, key: "referenceNumber")
                }
                referenceNumber = number
            }

            guard !ledger.transactions.contains(where: { $0.metaData.metaData[MetaDataKeys.activityId] == referenceNumber }) else {
                continue
            }

            transactions.append(try mapActivity(activity, date: postedDate, referenceNumber: referenceNumber))
        }
        return transactions
    }

    private func ledgerAccountName(lastFour: String) throws -> AccountName {
        guard let accountName = ledger.accounts.first(where: {
            $0.name.accountType == .liability && $0.metaData[MetaDataKeys.lastFour] == lastFour && $0.metaData[MetaDataKeys.importerType] == MetaDataKeys.importerTypeValue
        })?.name else {
            throw RogersBankMappingError.missingAccount(lastFour: lastFour)
        }
        return accountName
    }

}
