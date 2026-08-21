package com.kosli.demo.orders;

import java.math.BigDecimal;
import java.math.RoundingMode;

/**
 * Prices an order line.
 *
 * <p>This class exists to give the mutation-testing part of the demo something to chew on:
 * it has several branches and boundaries, and the unit tests deliberately cover only some
 * of them, so PIT leaves mutants alive and the mutation score lands below the policy
 * threshold.
 */
public final class OrderPricer {

    static final BigDecimal UNIT_PRICE = new BigDecimal("10.00");
    static final BigDecimal EXPEDITED_FEE = new BigDecimal("7.50");
    static final int BULK_THRESHOLD = 10;
    static final BigDecimal BULK_DISCOUNT = new BigDecimal("0.05");

    private OrderPricer() {
    }

    public static Quote quote(int quantity, String tier, boolean expedited) {
        if (quantity < 1) {
            throw new IllegalArgumentException("quantity must be at least 1");
        }
        if (quantity > 1000) {
            throw new IllegalArgumentException("quantity must not exceed 1000");
        }

        BigDecimal subtotal = UNIT_PRICE.multiply(BigDecimal.valueOf(quantity));
        BigDecimal discountRate = tierDiscount(tier);

        if (qualifiesForBulkDiscount(quantity)) {
            discountRate = discountRate.add(BULK_DISCOUNT);
        }

        BigDecimal discount = subtotal.multiply(discountRate);
        BigDecimal total = subtotal.subtract(discount);

        if (expedited) {
            total = total.add(EXPEDITED_FEE);
        }

        return new Quote(
                scale(subtotal),
                scale(discount),
                scale(total),
                discountRate.multiply(BigDecimal.valueOf(100)).setScale(1, RoundingMode.HALF_UP));
    }

    static BigDecimal tierDiscount(String tier) {
        if (tier == null) {
            return BigDecimal.ZERO;
        }
        return switch (tier.toUpperCase()) {
            case "GOLD" -> new BigDecimal("0.15");
            case "SILVER" -> new BigDecimal("0.10");
            case "BRONZE" -> new BigDecimal("0.05");
            default -> BigDecimal.ZERO;
        };
    }

    static boolean qualifiesForBulkDiscount(int quantity) {
        return quantity >= BULK_THRESHOLD;
    }

    private static BigDecimal scale(BigDecimal value) {
        return value.setScale(2, RoundingMode.HALF_UP);
    }

    public record Quote(BigDecimal subtotal, BigDecimal discount, BigDecimal total, BigDecimal discountPercent) {
    }
}
