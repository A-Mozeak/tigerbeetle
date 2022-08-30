package com.tigerbeetle;

public enum CreateAccountResult {
    Ok,
    LinkedEventFailed,

    ReservedFlag,
    ReservedField,

    IdMustNotBeZero,
    IdMustNotBeIntMax,
    LedgerMustNotBeZero,
    CodeMustNotBeZero,

    MutuallyExclusiveFlags,

    OverflowsDebits,
    OverflowsCredits,

    ExceedsCredits,
    ExceedsDebits,

    ExistsWithDifferentFlags,
    ExistsWithDifferentUser_data,
    ExistsWithDifferentLedger,
    ExistsWithDifferentCode,
    ExistsWithDifferentDebitsPending,
    ExistsWithDifferentDebitsPosted,
    ExistsWithDifferentCreditsPending,
    ExistsWithDifferentCreditsPosted,
    Exists;

    public static CreateAccountResult fromValue(int value) {       
        var values = CreateAccountResult.values();
        if (value < 0 || value >= values.length) throw new IllegalArgumentException();

        return values[value];
    }
}
