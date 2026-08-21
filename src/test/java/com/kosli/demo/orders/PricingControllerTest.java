package com.kosli.demo.orders;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(PricingController.class)
class PricingControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void healthEndpointReportsUp() throws Exception {
        mockMvc.perform(get("/api/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("UP"));
    }

    @Test
    void priceEndpointReturnsAQuote() throws Exception {
        mockMvc.perform(post("/api/price")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"quantity\":2,\"tier\":\"GOLD\",\"expedited\":false}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.total").value(17.00));
    }
}
