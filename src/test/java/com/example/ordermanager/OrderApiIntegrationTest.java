package com.example.ordermanager;

import com.example.ordermanager.repository.OrderRepository;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@SpringBootTest
@AutoConfigureMockMvc
@DisplayName("Order API - Pruebas de integración (contexto completo + JPA + H2)")
class OrderApiIntegrationTest {

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private ObjectMapper objectMapper;

    @Autowired
    private OrderRepository repository;

    @BeforeEach
    void cleanDatabase() {
        repository.deleteAll();
    }

    private long createOrder(String body) throws Exception {
        String response = mockMvc.perform(post("/api/orders")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(body))
                .andExpect(status().isCreated())
                .andReturn().getResponse().getContentAsString();
        JsonNode json = objectMapper.readTree(response);
        return json.get("id").asLong();
    }

    @Test
    @DisplayName("Ciclo de vida completo: crear, agregar ítem, confirmar, enviar y entregar")
    void shouldCompleteOrderLifecycle() throws Exception {
        long id = createOrder("""
                {"customerName":"Ana","items":[{"productName":"Teclado","quantity":2,"unitPrice":19990.00}]}
                """);

        mockMvc.perform(post("/api/orders/{id}/items", id)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"productName\":\"Mouse\",\"quantity\":1,\"unitPrice\":5000.50}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items.length()").value(2))
                .andExpect(jsonPath("$.totalAmount").value(44980.50));

        mockMvc.perform(put("/api/orders/{id}/confirm", id)).andExpect(jsonPath("$.status").value("CONFIRMED"));
        mockMvc.perform(put("/api/orders/{id}/ship", id)).andExpect(jsonPath("$.status").value("SHIPPED"));
        mockMvc.perform(put("/api/orders/{id}/deliver", id)).andExpect(jsonPath("$.status").value("DELIVERED"));

        mockMvc.perform(put("/api/orders/{id}/cancel", id))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.message").value("Un pedido entregado no puede cancelarse"));

        mockMvc.perform(get("/api/orders/{id}", id))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("DELIVERED"))
                .andExpect(jsonPath("$.createdAt").exists());
    }

    @Test
    @DisplayName("Regla de negocio persistida: no se modifican pedidos confirmados")
    void shouldRejectChangesAfterConfirmation() throws Exception {
        long id = createOrder("{\"customerName\":\"Luis\"}");
        mockMvc.perform(put("/api/orders/{id}/confirm", id)).andExpect(status().isOk());

        mockMvc.perform(post("/api/orders/{id}/items", id)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"productName\":\"Mouse\",\"quantity\":1,\"unitPrice\":10}"))
                .andExpect(status().isConflict());

        assertEquals(0, repository.findById(id).orElseThrow().getItems().size());
    }

    @Test
    @DisplayName("Filtro por estado y eliminación contra la base de datos")
    void shouldFilterByStatusAndDelete() throws Exception {
        long pending = createOrder("{\"customerName\":\"Uno\"}");
        long cancelled = createOrder("{\"customerName\":\"Dos\"}");
        mockMvc.perform(put("/api/orders/{id}/cancel", cancelled)).andExpect(status().isOk());

        mockMvc.perform(get("/api/orders/status/CANCELLED"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.length()").value(1))
                .andExpect(jsonPath("$[0].id").value(cancelled));

        mockMvc.perform(delete("/api/orders/{id}", pending)).andExpect(status().isNoContent());
        mockMvc.perform(get("/api/orders/{id}", pending)).andExpect(status().isNotFound());
        assertEquals(1, repository.count());
    }

    @Test
    @DisplayName("Actuator: health, liveness y readiness disponibles para el orquestador")
    void shouldExposeHealthProbes() throws Exception {
        mockMvc.perform(get("/actuator/health")).andExpect(status().isOk()).andExpect(jsonPath("$.status").value("UP"));
        mockMvc.perform(get("/actuator/health/liveness")).andExpect(status().isOk());
        mockMvc.perform(get("/actuator/health/readiness")).andExpect(status().isOk());
    }
}
