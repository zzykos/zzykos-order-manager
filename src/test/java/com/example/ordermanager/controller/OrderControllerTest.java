package com.example.ordermanager.controller;

import com.example.ordermanager.exception.InvalidOrderStateException;
import com.example.ordermanager.exception.OrderNotFoundException;
import com.example.ordermanager.model.Order;
import com.example.ordermanager.model.OrderItem;
import com.example.ordermanager.model.OrderStatus;
import com.example.ordermanager.service.OrderService;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.util.List;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

@WebMvcTest(OrderController.class)
@DisplayName("OrderController - Pruebas de integración web")
class OrderControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockitoBean
    private OrderService service;

    @Test
    @DisplayName("GET /api/orders: retorna 200 con lista")
    void shouldReturnAllOrders() throws Exception {
        when(service.getAllOrders()).thenReturn(List.of(new Order("A"), new Order("B")));

        mockMvc.perform(get("/api/orders"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.length()").value(2));
    }

    @Test
    @DisplayName("GET /api/orders/{id}: retorna 200 si existe")
    void shouldReturnOrderById() throws Exception {
        Order order = new Order("Juan");
        order.setId(1L);
        when(service.getOrderById(1L)).thenReturn(order);

        mockMvc.perform(get("/api/orders/1"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.customerName").value("Juan"));
    }

    @Test
    @DisplayName("GET /api/orders/{id}: retorna 404 si no existe")
    void shouldReturn404WhenNotFound() throws Exception {
        when(service.getOrderById(99L)).thenThrow(new OrderNotFoundException(99L));

        mockMvc.perform(get("/api/orders/99"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.status").value(404));
    }

    @Test
    @DisplayName("POST /api/orders: retorna 201 con datos válidos")
    void shouldCreateOrder() throws Exception {
        Order created = new Order("Juan");
        created.setId(1L);
        when(service.createOrder(any())).thenReturn(created);

        String body = "{\"customerName\":\"Juan\",\"items\":[]}";

        mockMvc.perform(post("/api/orders")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(body))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.id").value(1));
    }

    @Test
    @DisplayName("POST /api/orders: retorna 400 si customerName vacío")
    void shouldReturn400WhenCustomerNameEmpty() throws Exception {
        String body = "{\"customerName\":\"\",\"items\":[]}";

        mockMvc.perform(post("/api/orders")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(body))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.fields.customerName").exists());

        verify(service, never()).createOrder(any());
    }

    @Test
    @DisplayName("PUT /api/orders/{id}/confirm: retorna 200")
    void shouldConfirmOrder() throws Exception {
        Order confirmed = new Order("Juan");
        confirmed.setId(1L);
        confirmed.setStatus(OrderStatus.CONFIRMED);
        when(service.confirmOrder(1L)).thenReturn(confirmed);

        mockMvc.perform(put("/api/orders/1/confirm"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("CONFIRMED"));
    }

    @Test
    @DisplayName("PUT /api/orders/{id}/confirm: retorna 409 si estado inválido")
    void shouldReturn409WhenInvalidTransition() throws Exception {
        when(service.confirmOrder(1L)).thenThrow(
                new InvalidOrderStateException("SHIPPED", "CONFIRMED"));

        mockMvc.perform(put("/api/orders/1/confirm"))
                .andExpect(status().isConflict());
    }

    @Test
    @DisplayName("DELETE /api/orders/{id}: retorna 204")
    void shouldDeleteOrder() throws Exception {
        doNothing().when(service).deleteOrder(1L);

        mockMvc.perform(delete("/api/orders/1"))
                .andExpect(status().isNoContent());
    }

    @Test
    @DisplayName("DELETE /api/orders/{id}: retorna 404 si no existe")
    void shouldReturn404WhenDeletingMissingOrder() throws Exception {
        doThrow(new OrderNotFoundException(99L)).when(service).deleteOrder(99L);

        mockMvc.perform(delete("/api/orders/99"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.status").value(404));
    }

    @Test
    @DisplayName("GET /api/orders/status/{status}: retorna 200 filtrado")
    void shouldReturnOrdersByStatus() throws Exception {
        Order shipped = new Order("Ana");
        shipped.setStatus(OrderStatus.SHIPPED);
        when(service.getOrdersByStatus(OrderStatus.SHIPPED)).thenReturn(List.of(shipped));

        mockMvc.perform(get("/api/orders/status/SHIPPED"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.length()").value(1))
                .andExpect(jsonPath("$[0].status").value("SHIPPED"));
    }

    @Test
    @DisplayName("GET /api/orders/status/{status}: retorna 400 si el estado no existe")
    void shouldReturn400WhenStatusIsUnknown() throws Exception {
        mockMvc.perform(get("/api/orders/status/LOST"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.status").value(400));

        verify(service, never()).getOrdersByStatus(any());
    }

    @Test
    @DisplayName("POST /api/orders/{id}/items: retorna 200 con ítem agregado")
    void shouldAddItem() throws Exception {
        Order order = new Order("Juan");
        order.setId(1L);
        order.addItem(new OrderItem("Mouse", 2, new BigDecimal("25.50")));
        when(service.addItem(eq(1L), any())).thenReturn(order);

        mockMvc.perform(post("/api/orders/1/items")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"productName\":\"Mouse\",\"quantity\":2,\"unitPrice\":25.50}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items.length()").value(1))
                .andExpect(jsonPath("$.totalAmount").value(51.00));
    }

    @Test
    @DisplayName("POST /api/orders/{id}/items: retorna 400 con cantidad y precio inválidos")
    void shouldReturn400WhenItemIsInvalid() throws Exception {
        mockMvc.perform(post("/api/orders/1/items")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"productName\":\"Mouse\",\"quantity\":0,\"unitPrice\":-5}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.fields.quantity").exists())
                .andExpect(jsonPath("$.fields.unitPrice").exists());

        verify(service, never()).addItem(any(), any());
    }

    @Test
    @DisplayName("POST /api/orders: retorna 400 si el JSON está mal formado")
    void shouldReturn400WhenBodyIsMalformed() throws Exception {
        mockMvc.perform(post("/api/orders")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"customerName\":"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.status").value(400));

        verify(service, never()).createOrder(any());
    }

    @Test
    @DisplayName("PUT /api/orders/{id}/ship: retorna 200")
    void shouldShipOrder() throws Exception {
        Order shipped = new Order("Juan");
        shipped.setStatus(OrderStatus.SHIPPED);
        when(service.shipOrder(1L)).thenReturn(shipped);

        mockMvc.perform(put("/api/orders/1/ship"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("SHIPPED"));
    }

    @Test
    @DisplayName("PUT /api/orders/{id}/deliver: retorna 200")
    void shouldDeliverOrder() throws Exception {
        Order delivered = new Order("Juan");
        delivered.setStatus(OrderStatus.DELIVERED);
        when(service.deliverOrder(1L)).thenReturn(delivered);

        mockMvc.perform(put("/api/orders/1/deliver"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("DELIVERED"));
    }

    @Test
    @DisplayName("PUT /api/orders/{id}/cancel: retorna 200")
    void shouldCancelOrder() throws Exception {
        Order cancelled = new Order("Juan");
        cancelled.setStatus(OrderStatus.CANCELLED);
        when(service.cancelOrder(1L)).thenReturn(cancelled);

        mockMvc.perform(put("/api/orders/1/cancel"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value("CANCELLED"));
    }

    @Test
    @DisplayName("Error inesperado: retorna 500 sin exponer detalles internos")
    void shouldReturn500WithoutLeakingDetails() throws Exception {
        when(service.getAllOrders()).thenThrow(new IllegalStateException("conexión rechazada a db:5432"));

        mockMvc.perform(get("/api/orders"))
                .andExpect(status().isInternalServerError())
                .andExpect(jsonPath("$.status").value(500))
                .andExpect(jsonPath("$.message").value("Error interno del servidor. Contacte al administrador."));
    }
}
