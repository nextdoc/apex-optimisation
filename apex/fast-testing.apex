/**
 * ============================================================================
 * Functional Style Domain Logic — a base for exploring Apex coding styles
 * ============================================================================
 *
 * WARNING: run through Execute Anonymous, this script writes to the database.
 * It is safe to run in Streamline, which rolls back every change automatically.
 *
 * Story: each Account's AnnualRevenue is its won Opportunity Amount over the
 * trailing 12 months, and its Rating compares that to the 12 months before:
 * Hot = up, Warm = flat, Cold = down or nothing won. Roll-up summaries cannot
 * filter on relative dates, so this has no declarative equivalent.
 *
 * Anonymous Apex classes are inner classes, so they cannot hold static members.
 */

// === CLASSES ===

enum TestMode { IMPERATIVE, IMPERATIVE_SHELL, FUNCTIONAL }

/**
 * @description Lets the shared tests call any of the three handler styles through one type.
 * Its methods mirror the TriggerHandler after-context methods.
 */
interface OpportunityHandler {
    void afterInsert();
    void afterUpdate();
    void afterDelete();
    void afterUndelete();
}

/**
 * @description Imperative style: collects, queries, calculates and updates Accounts in one method.
 *
 * Follows https://github.com/kevinohara80/sfdc-trigger-framework, the most-starred
 * open-source Apex trigger framework. Deployed, it would be
 * `class OpportunityTriggerHandler extends TriggerHandler` with `override` on
 * each context method, and the trigger body would be:
 *     new OpportunityTriggerHandler().run();
 * Anonymous Apex cannot register a trigger, so the tests construct the handler
 * with explicit Trigger.new / Trigger.oldMap values and call the context method.
 */
class OpportunityTriggerHandler implements OpportunityHandler {
    private List<Opportunity> newList;
    private Map<Id, Opportunity> oldMap;

    OpportunityTriggerHandler() {
        this((List<Opportunity>) Trigger.new, (Map<Id, Opportunity>) Trigger.oldMap);
    }

    OpportunityTriggerHandler(List<Opportunity> newList, Map<Id, Opportunity> oldMap) {
        this.newList = newList;
        this.oldMap = oldMap;
    }

    public void afterInsert() {
        recalculateAccounts();
    }

    public void afterUpdate() {
        recalculateAccounts();
    }

    public void afterDelete() {
        recalculateAccounts();
    }

    public void afterUndelete() {
        recalculateAccounts();
    }

    /**
     * @description Sets each affected Account's AnnualRevenue to its won Opportunity Amount over the
     * trailing 12 months, and its Rating to Hot, Warm or Cold as that is up, flat or down on the
     * 12 months before (Cold when nothing was won). This needs code because roll-up summary filters
     * cannot use relative dates and cannot write to standard fields.
     */
    private void recalculateAccounts() {

        // 1. Collect every Account touched, including the old parent of a moved Opportunity
        Set<Id> accountIds = new Set<Id>();
        if (newList != null) {
            for (Opportunity opp : newList) accountIds.add(opp.AccountId);
        }
        if (oldMap != null) {
            for (Opportunity opp : oldMap.values()) accountIds.add(opp.AccountId);
        }
        accountIds.remove(null);
        if (accountIds.isEmpty()) return;

        // 2. Start each Account at zero for both years
        Map<Id, Account> accountsById = new Map<Id, Account>();
        Map<Id, Decimal> priorRevenueById = new Map<Id, Decimal>();
        for (Id accountId : accountIds) {
            accountsById.put(accountId, new Account(Id = accountId, AnnualRevenue = 0));
            priorRevenueById.put(accountId, 0);
        }

        // 3. Add each won Amount to this year on the Account, or to the prior year
        Date today = Date.today();
        Date yearAgo = today.addYears(-1);
        Date twoYearsAgo = today.addYears(-2);
        for (List<Opportunity> opps : [
                SELECT AccountId, Amount, CloseDate
                FROM Opportunity
                WHERE AccountId IN :accountIds
                AND IsWon = true
                AND Amount != null
                AND CloseDate > :twoYearsAgo
                AND CloseDate <= :today
        ]) {
            for (Opportunity opp : opps) {
                if (opp.CloseDate > yearAgo) {
                    Account acct = accountsById.get(opp.AccountId);
                    acct.AnnualRevenue += opp.Amount;
                } else {
                    priorRevenueById.put(opp.AccountId, priorRevenueById.get(opp.AccountId) + opp.Amount);
                }
            }
        }

        // 4. Rate each Account by comparing this year to the prior year
        for (Account acct : accountsById.values()) {
            Decimal prior = priorRevenueById.get(acct.Id);
            if (acct.AnnualRevenue == 0 || acct.AnnualRevenue < prior) {
                acct.Rating = 'Cold';
            } else if (acct.AnnualRevenue > prior) {
                acct.Rating = 'Hot';
            } else {
                acct.Rating = 'Warm';
            }
        }

        // 5. Save every Account in one DML
        update accountsById.values();
    }
}

/**
 * @description Functional core: no SOQL, DML or Date.today(), so it can be tested without the database.
 */
class AccountRevenueCore {

    /** @description Returns the Account Ids on new and old Opportunities, so a moved Opportunity updates both parents. */
    Set<Id> affectedAccountIds(List<Opportunity> newList, Map<Id, Opportunity> oldMap) {
        Set<Id> accountIds = new Set<Id>();
        if (newList != null) {
            for (Opportunity opp : newList) accountIds.add(opp.AccountId);
        }
        if (oldMap != null) {
            for (Opportunity opp : oldMap.values()) accountIds.add(opp.AccountId);
        }
        accountIds.remove(null);
        return accountIds;
    }

    /** @description Returns each Account with AnnualRevenue and Rating from won Opportunities in the two years to today. */
    List<Account> recalculate(Set<Id> accountIds, List<Opportunity> wonOpps, Date today) {
        Date yearAgo = today.addYears(-1);
        Date twoYearsAgo = today.addYears(-2);
        Map<Id, Decimal> currentById = zeroed(accountIds);
        Map<Id, Decimal> priorById = zeroed(accountIds);

        for (Opportunity opp : wonOpps) {
            if (opp.Amount == null || !accountIds.contains(opp.AccountId)
                    || opp.CloseDate > today || opp.CloseDate <= twoYearsAgo) continue;
            Map<Id, Decimal> totals = opp.CloseDate > yearAgo ? currentById : priorById;
            totals.put(opp.AccountId, totals.get(opp.AccountId) + opp.Amount);
        }

        List<Account> accounts = new List<Account>();
        for (Id accountId : accountIds) {
            Decimal current = currentById.get(accountId);
            accounts.add(new Account(
                    Id = accountId,
                    AnnualRevenue = current,
                    Rating = rating(current, priorById.get(accountId))));
        }
        return accounts;
    }

    /** @description Hot when revenue is up on the prior year, Warm when flat, Cold when down or zero. */
    String rating(Decimal current, Decimal prior) {
        if (current == 0 || current < prior) return 'Cold';
        return current > prior ? 'Hot' : 'Warm';
    }

    private Map<Id, Decimal> zeroed(Set<Id> accountIds) {
        Map<Id, Decimal> totals = new Map<Id, Decimal>();
        for (Id accountId : accountIds) totals.put(accountId, 0);
        return totals;
    }
}

/**
 * @description Imperative shell: reads from the database, asks the core for the new values, then writes them.
 */
class ImperativeShellOpportunityTriggerHandler implements OpportunityHandler {
    private List<Opportunity> newList;
    private Map<Id, Opportunity> oldMap;
    private AccountRevenueCore core = new AccountRevenueCore();

    ImperativeShellOpportunityTriggerHandler() {
        this((List<Opportunity>) Trigger.new, (Map<Id, Opportunity>) Trigger.oldMap);
    }

    ImperativeShellOpportunityTriggerHandler(List<Opportunity> newList, Map<Id, Opportunity> oldMap) {
        this.newList = newList;
        this.oldMap = oldMap;
    }

    public void afterInsert() {
        recalculateAccounts();
    }

    public void afterUpdate() {
        recalculateAccounts();
    }

    public void afterDelete() {
        recalculateAccounts();
    }

    public void afterUndelete() {
        recalculateAccounts();
    }

    private void recalculateAccounts() {
        Set<Id> accountIds = core.affectedAccountIds(newList, oldMap);
        if (accountIds.isEmpty()) return;

        Date today = Date.today();
        Date twoYearsAgo = today.addYears(-2);
        List<Opportunity> wonOpps = [
                SELECT AccountId, Amount, CloseDate
                FROM Opportunity
                WHERE AccountId IN :accountIds
                AND IsWon = true
                AND Amount != null
                AND CloseDate > :twoYearsAgo
                AND CloseDate <= :today
        ];

        update core.recalculate(accountIds, wonOpps, today);
    }
}

/**
 * @description Runs AccountRevenueCore against in-memory records in place of the database.
 */
class InMemoryCoreHandler implements OpportunityHandler {
    private List<Opportunity> newList;
    private Map<Id, Opportunity> oldMap;
    private Map<Id, Opportunity> storedOpps;
    private Map<Id, Account> storedAccounts;
    private String wonStage;
    private AccountRevenueCore core = new AccountRevenueCore();

    InMemoryCoreHandler(List<Opportunity> newList, Map<Id, Opportunity> oldMap,
            Map<Id, Opportunity> storedOpps, Map<Id, Account> storedAccounts, String wonStage) {
        this.newList = newList;
        this.oldMap = oldMap;
        this.storedOpps = storedOpps;
        this.storedAccounts = storedAccounts;
        this.wonStage = wonStage;
    }

    public void afterInsert() {
        recalculateAccounts();
    }

    public void afterUpdate() {
        recalculateAccounts();
    }

    public void afterDelete() {
        recalculateAccounts();
    }

    public void afterUndelete() {
        recalculateAccounts();
    }

    private void recalculateAccounts() {
        // Stands in for the shell's IsWon filter, since IsWon is only set on records read from the database.
        List<Opportunity> wonOpps = new List<Opportunity>();
        for (Opportunity opp : storedOpps.values()) {
            if (opp.StageName == wonStage) wonOpps.add(opp);
        }
        Set<Id> accountIds = core.affectedAccountIds(newList, oldMap);
        for (Account acct : core.recalculate(accountIds, wonOpps, Date.today())) {
            storedAccounts.put(acct.Id, acct);
        }
    }
}

/**
 * @description Runs the same tests and assertions against one handler style, chosen by TestMode.
 * Database modes use real DML and SOQL. The functional mode keeps records in memory with fake Ids.
 * runAll() logs each test's time in ms under a header naming the mode.
 */
class OpportunityTriggerHandlerTest {
    private Date today = Date.today();
    private String wonStage = 'Closed Won';
    private TestMode mode;
    private Integer lastFakeId = 0;
    private Map<Id, Opportunity> storedOpps = new Map<Id, Opportunity>();
    private Map<Id, Account> storedAccounts = new Map<Id, Account>();

    OpportunityTriggerHandlerTest(TestMode mode) {
        this.mode = mode;
    }

    /** @description Mode name for log lines, e.g. 'imperative shell'. */
    private String label() {
        return mode.name().toLowerCase().replace('_', ' ');
    }

    /** @description True when the mode runs without the database. */
    private Boolean inMemory() {
        return mode == TestMode.FUNCTIONAL;
    }

    /**
     * @description Returns the OpportunityHandler implementation for this test mode.
     */
    private OpportunityHandler handlerDispatch(List<Opportunity> newList, Map<Id, Opportunity> oldMap) {
        if (inMemory()) return new InMemoryCoreHandler(newList, oldMap, storedOpps, storedAccounts, wonStage);
        if (mode == TestMode.IMPERATIVE_SHELL) return new ImperativeShellOpportunityTriggerHandler(newList, oldMap);
        return new OpportunityTriggerHandler(newList, oldMap);
    }

    /** @description Inserts records, or gives them fake Ids and stores Opportunities in memory. */
    private void insertRecords(List<SObject> records) {
        if (!inMemory()) {
            insert records;
            return;
        }
        for (SObject record : records) {
            lastFakeId++;
            String keyPrefix = record.getSObjectType().getDescribe().getKeyPrefix();
            record.Id = Id.valueOf(keyPrefix + String.valueOf(lastFakeId).leftPad(12, '0'));
            if (record instanceof Opportunity) storedOpps.put(record.Id, (Opportunity) record);
        }
    }

    /**
     * @description In memory, the stored records are the same instances the test changes, so there is nothing to write.
     */
    private void updateRecords(List<SObject> records) {
        if (!inMemory()) update records;
    }

    /** @description Deletes records, or removes them from the in-memory store. */
    private void deleteRecords(List<SObject> records) {
        if (!inMemory()) {
            delete records;
            return;
        }
        for (SObject record : records) storedOpps.remove(record.Id);
    }

    /** @description Returns the Account as stored, from the database or from memory. */
    private Account reload(Account acct) {
        if (inMemory()) return storedAccounts.get(acct.Id);
        return [SELECT AnnualRevenue, Rating FROM Account WHERE Id = :acct.Id];
    }

    /**
     * @description In a deployed test class this fixture would be created in a @TestSetup method.
     */
    private Account account(String name) {
        Account acct = new Account(Name = name);
        insertRecords(new List<Account>{ acct });
        return acct;
    }

    /**
     * @description In a deployed test class these fixtures would be created in a @TestSetup method.
     */
    private List<Opportunity> wonOpps(Account acct, Integer count, Decimal amount, Date closeDate) {
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < count; i++) {
            opps.add(new Opportunity(
                    Name = acct.Name + ' won ' + i,
                    AccountId = acct.Id,
                    StageName = wonStage,
                    Amount = amount,
                    CloseDate = closeDate));
        }
        return opps;
    }

    /**
     * @description Asserts the Account's stored AnnualRevenue and Rating,
     * read from the database or from memory by mode.
     */
    private void assertAccount(Account acct, Decimal annualRevenue, String rating) {
        Account stored = reload(acct);
        System.assertEquals(annualRevenue, stored.AnnualRevenue, acct.Name + ' AnnualRevenue');
        System.assertEquals(rating, stored.Rating, acct.Name + ' Rating');
    }

    /**
     * @description A full 200-record batch rates each Account by its won revenue against the prior year:
     * up is Hot, flat is Warm, down is Cold. Open Opportunities are not counted.
     */
    void testBulkInsert() {
        Account growing = account('Growing');
        Account flat = account('Flat');
        Account shrinking = account('Shrinking');
        Date thisYear = today.addMonths(-3);
        Date lastYear = today.addMonths(-15);

        List<Opportunity> opps = new List<Opportunity>();
        opps.addAll(wonOpps(growing, 60, 1000, thisYear));
        opps.addAll(wonOpps(growing, 20, 1000, lastYear));
        opps.addAll(wonOpps(flat, 30, 500, thisYear));
        opps.addAll(wonOpps(flat, 30, 500, lastYear));
        opps.addAll(wonOpps(shrinking, 10, 1000, thisYear));
        opps.addAll(wonOpps(shrinking, 40, 1000, lastYear));
        for (Opportunity open : wonOpps(shrinking, 10, 5000, thisYear)) {
            open.StageName = 'Prospecting';
            opps.add(open);
        }
        System.assertEquals(200, opps.size(), 'one full trigger batch');
        insertRecords(opps);

        handlerDispatch(opps, null).afterInsert();

        assertAccount(growing, 60000, 'Hot');
        assertAccount(flat, 15000, 'Warm');
        assertAccount(shrinking, 10000, 'Cold');
    }

    /**
     * @description Moving a won Opportunity to another Account recalculates both:
     * the old parent loses its Amount and the new parent gains it.
     */
    void testReparent() {
        Account source = account('Source');
        Account target = account('Target');
        List<Opportunity> opps = wonOpps(source, 2, 1000, today.addMonths(-1));
        opps.addAll(wonOpps(target, 1, 1000, today.addMonths(-13)));
        insertRecords(opps);
        handlerDispatch(opps, null).afterInsert();
        assertAccount(target, 0, 'Cold');

        Opportunity moved = opps[0];
        Map<Id, Opportunity> oldMap = new Map<Id, Opportunity>{ moved.Id => moved.clone(true) };
        moved.AccountId = target.Id;
        updateRecords(new List<Opportunity>{ moved });

        handlerDispatch(new List<Opportunity>{ moved }, oldMap).afterUpdate();

        assertAccount(source, 1000, 'Hot');
        assertAccount(target, 1000, 'Warm');
    }

    /**
     * @description Deleting the only won Opportunity in the last 12 months zeroes AnnualRevenue
     * and rates the Account Cold, even though revenue was won the year before.
     */
    void testDelete() {
        Account acct = account('Deleted');
        Opportunity recent = wonOpps(acct, 1, 1000, today.addMonths(-2))[0];
        Opportunity older = wonOpps(acct, 1, 500, today.addMonths(-14))[0];
        insertRecords(new List<Opportunity>{ recent, older });
        handlerDispatch(new List<Opportunity>{ recent, older }, null).afterInsert();
        assertAccount(acct, 1000, 'Hot');

        Map<Id, Opportunity> oldMap = new Map<Id, Opportunity>{ recent.Id => recent };
        deleteRecords(new List<Opportunity>{ recent });

        handlerDispatch(null, oldMap).afterDelete();

        assertAccount(acct, 0, 'Cold');
    }

    /** @description Logs a bar of one '=' per 20 ms, aligned across tests, followed by the ms count. */
    private void logTiming(String testName, Long ms) {
        Integer barLength = Math.ceil(ms / 20.0).intValue();
        // Non-breaking spaces, since the Streamline log panel collapses ordinary ones.
        System.debug((testName + ':').rightPad(16, '\u00A0') + '='.repeat(barLength) + ' ' + ms + ' ms');
    }

    void runAll() {
        System.debug('---------- ' + label() + ' ----------');
        Long start = System.currentTimeMillis();
        testBulkInsert();
        logTiming('testBulkInsert', System.currentTimeMillis() - start);

        start = System.currentTimeMillis();
        testReparent();
        logTiming('testReparent', System.currentTimeMillis() - start);

        start = System.currentTimeMillis();
        testDelete();
        logTiming('testDelete', System.currentTimeMillis() - start);

        System.debug('All ' + label() + ' tests passed');
    }
}

// === METHODS ===

/**
 * @description Pays the one-off cost of the transaction's first Account and Opportunity DML before any
 * timing starts. Without it, whichever pass runs first measures that cost in its bulk insert and delete.
 * Describe calls and SOQL alone do not remove it.
 */
void warmUpDatabase() {
    Long start = System.currentTimeMillis();
    Account acct = new Account(Name = 'Warm-up');
    insert acct;
    Opportunity opp = new Opportunity(Name = 'Warm-up', AccountId = acct.Id, StageName = 'Prospecting', CloseDate = Date.today());
    insert opp;
    update acct;
    delete opp;
    delete acct;
    System.debug('Database warm-up, not timed in results: ' + (System.currentTimeMillis() - start) + ' ms');
}

// === CODE ===

warmUpDatabase();
new OpportunityTriggerHandlerTest(TestMode.IMPERATIVE).runAll();
new OpportunityTriggerHandlerTest(TestMode.IMPERATIVE_SHELL).runAll();
new OpportunityTriggerHandlerTest(TestMode.FUNCTIONAL).runAll();
