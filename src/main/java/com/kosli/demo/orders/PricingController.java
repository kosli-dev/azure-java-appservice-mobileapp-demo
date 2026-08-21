package com.kosli.demo.orders;

import java.math.BigDecimal;
import java.util.Map;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api")
public class PricingController {

    private final String commitSha;

    public PricingController(@Value("${app.commit-sha:unknown}") String commitSha) {
        this.commitSha = commitSha;
    }

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("status", "UP", "service", "orders-api");
    }

    @GetMapping("/version")
    public Map<String, String> version() {
        return Map.of("service", "orders-api", "commit", commitSha);
    }

    @PostMapping("/price")
    public ResponseEntity<PriceResponse> price(@RequestBody PriceRequest request) {
        OrderPricer.Quote quote = OrderPricer.quote(request.quantity(), request.tier(), request.expedited());
        return ResponseEntity.ok(new PriceResponse(
                request.quantity(),
                request.tier(),
                quote.subtotal(),
                quote.discount(),
                quote.total(),
                quote.discountPercent()));
    }

    public record PriceRequest(int quantity, String tier, boolean expedited) {
    }

    public record PriceResponse(
            int quantity,
            String tier,
            BigDecimal subtotal,
            BigDecimal discount,
            BigDecimal total,
            BigDecimal discountPercent) {
    }
}
