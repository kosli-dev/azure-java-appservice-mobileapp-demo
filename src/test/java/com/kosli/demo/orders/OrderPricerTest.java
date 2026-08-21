package com.kosli.demo.orders;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.math.BigDecimal;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * Unit tests for {@link OrderPricer}.
 *
 * <p>These tests all pass, which is what makes the JUnit attestation compliant. They do NOT
 * cover every branch and boundary, which is what makes the mutation-testing attestation
 * non-compliant - that is the gap the demo waiver is about.
 */
class OrderPricerTest {

    @Test
    @DisplayName("standard customer, single item, no expedited shipping")
    void standardSingleItem() {
        OrderPricer.Quote quote = OrderPricer.quote(1, "STANDARD", false);

        assertThat(quote.subtotal()).isEqualByComparingTo("10.00");
        assertThat(quote.discount()).isEqualByComparingTo("0.00");
        assertThat(quote.total()).isEqualByComparingTo("10.00");
    }

    @Test
    @DisplayName("gold customer gets 15% off")
    void goldTierDiscount() {
        OrderPricer.Quote quote = OrderPricer.quote(2, "GOLD", false);

        assertThat(quote.subtotal()).isEqualByComparingTo("20.00");
        assertThat(quote.discount()).isEqualByComparingTo("3.00");
        assertThat(quote.total()).isEqualByComparingTo("17.00");
    }

    @Test
    @DisplayName("bulk orders stack an extra 5% on top of the tier discount")
    void bulkDiscountStacks() {
        OrderPricer.Quote quote = OrderPricer.quote(12, "GOLD", false);

        assertThat(quote.subtotal()).isEqualByComparingTo("120.00");
        assertThat(quote.total()).isEqualByComparingTo("96.00");
    }

    @Test
    @DisplayName("tier lookup is case insensitive")
    void tierLookupIsCaseInsensitive() {
        assertThat(OrderPricer.tierDiscount("gold")).isEqualByComparingTo(new BigDecimal("0.15"));
    }

    @Test
    @DisplayName("quantity below one is rejected")
    void rejectsNonPositiveQuantity() {
        assertThatThrownBy(() -> OrderPricer.quote(0, "GOLD", false))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("at least 1");
    }
}
