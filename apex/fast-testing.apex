// ============================================================================
// Functional Style Domain Logic — a base for exploring Apex coding styles
// ============================================================================
//
// Story: each Account's AnnualRevenue is its won Opportunity Amount over the
// trailing 12 months, and its Rating compares that to the 12 months before:
// Hot = up, Warm = flat, Cold = down or nothing won. Roll-up summaries cannot
// filter on relative dates, so this has no declarative equivalent.
//
// The handler follows https://github.com/kevinohara80/sfdc-trigger-framework,
// the most-starred open-source Apex trigger framework. Deployed, it would be
// `class OpportunityTriggerHandler extends TriggerHandler` with `override` on
// each context method, and the trigger body would be:
//     new OpportunityTriggerHandler().run();
// Anonymous Apex cannot register a trigger, so the tests construct the handler
// with explicit Trigger.new / Trigger.oldMap values and call the context method.
//
// Anonymous Apex classes are inner classes, so they cannot hold static members.

// === CLASSES ===

class OpportunityTriggerHandler {
    private List<Opportunity> newList;
    private Map<Id, Opportunity> oldMap;

    OpportunityTriggerHandler() {
        this((List<Opportunity>) Trigger.new, (Map<Id, Opportunity>) Trigger.oldMap);
    }

    OpportunityTriggerHandler(List<Opportunity> newList, Map<Id, Opportunity> oldMap) {
        this.newList = newList;
        this.oldMap = oldMap;
    }

    void afterInsert() {
        recalculateAccounts();
    }

    void afterUpdate() {
        recalculateAccounts();
    }

    void afterDelete() {
        recalculateAccounts();
    }

    void afterUndelete() {
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

class OpportunityTriggerHandlerTest {
    private Date today = Date.today();

    // In a deployed test class this fixture would be created in a @TestSetup method.
    private Account account(String name) {
        Account acct = new Account(Name = name);
        insert acct;
        return acct;
    }

    // In a deployed test class these fixtures would be created in a @TestSetup method.
    private List<Opportunity> wonOpps(Account acct, Integer count, Decimal amount, Date closeDate) {
        List<Opportunity> opps = new List<Opportunity>();
        for (Integer i = 0; i < count; i++) {
            opps.add(new Opportunity(
                    Name = acct.Name + ' won ' + i,
                    AccountId = acct.Id,
                    StageName = 'Closed Won',
                    Amount = amount,
                    CloseDate = closeDate));
        }
        return opps;
    }

    private Account reload(Account acct) {
        return [SELECT AnnualRevenue, Rating FROM Account WHERE Id = :acct.Id];
    }

    private void assertAccount(Account acct, Decimal annualRevenue, String rating) {
        Account stored = reload(acct);
        System.assertEquals(annualRevenue, stored.AnnualRevenue, acct.Name + ' AnnualRevenue');
        System.assertEquals(rating, stored.Rating, acct.Name + ' Rating');
    }

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
        insert opps;

        new OpportunityTriggerHandler(opps, null).afterInsert();

        assertAccount(growing, 60000, 'Hot');
        assertAccount(flat, 15000, 'Warm');
        assertAccount(shrinking, 10000, 'Cold');
    }

    void testReparent() {
        Account source = account('Source');
        Account target = account('Target');
        List<Opportunity> opps = wonOpps(source, 2, 1000, today.addMonths(-1));
        opps.addAll(wonOpps(target, 1, 1000, today.addMonths(-13)));
        insert opps;
        new OpportunityTriggerHandler(opps, null).afterInsert();
        assertAccount(target, 0, 'Cold');

        Opportunity moved = opps[0];
        Map<Id, Opportunity> oldMap = new Map<Id, Opportunity>{ moved.Id => moved.clone(true) };
        moved.AccountId = target.Id;
        update moved;

        new OpportunityTriggerHandler(new List<Opportunity>{ moved }, oldMap).afterUpdate();

        assertAccount(source, 1000, 'Hot');
        assertAccount(target, 1000, 'Warm');
    }

    void testDelete() {
        Account acct = account('Deleted');
        Opportunity recent = wonOpps(acct, 1, 1000, today.addMonths(-2))[0];
        Opportunity older = wonOpps(acct, 1, 500, today.addMonths(-14))[0];
        insert new List<Opportunity>{ recent, older };
        new OpportunityTriggerHandler(new List<Opportunity>{ recent, older }, null).afterInsert();
        assertAccount(acct, 1000, 'Hot');

        Map<Id, Opportunity> oldMap = new Map<Id, Opportunity>{ recent.Id => recent };
        delete recent;

        new OpportunityTriggerHandler(null, oldMap).afterDelete();

        assertAccount(acct, 0, 'Cold');
    }

    void runAll() {
        Long start = System.currentTimeMillis();
        testBulkInsert();
        System.debug('testBulkInsert: ' + (System.currentTimeMillis() - start) + ' ms');

        start = System.currentTimeMillis();
        testReparent();
        System.debug('testReparent: ' + (System.currentTimeMillis() - start) + ' ms');

        start = System.currentTimeMillis();
        testDelete();
        System.debug('testDelete: ' + (System.currentTimeMillis() - start) + ' ms');

        System.debug('All OpportunityTriggerHandler tests passed');
    }
}

// === CODE ===

new OpportunityTriggerHandlerTest().runAll();
