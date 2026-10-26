package com.example.ordermanager.model;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.junit.jupiter.api.Assertions.*;

@DisplayName("Order - Pruebas unitarias del modelo")
class OrderTest {

    @Test
    @DisplayName("constructor: inicia en PENDING con total 0 y nombre normalizado")
    void shouldInitializeNewOrder() {
        Order order = new Order("  Juan  ");

        assertEquals("Juan", order.getCustomerName());
        assertEquals(OrderStatus.PENDING, order.getStatus());
        assertEquals(BigDecimal.ZERO, order.getTotalAmount());
        assertTrue(order.getItems().isEmpty());
    }

    @Test
    @DisplayName("constructor: rechaza cliente nulo o vacío")
    void shouldRejectBlankCustomer() {
        assertThrows(IllegalArgumentException.class, () -> new Order(null));
        assertThrows(IllegalArgumentException.class, () -> new Order("   "));
    }

    @Test
    @DisplayName("addItem: recalcula el total con varios ítems")
    void shouldRecalculateTotal() {
        Order order = new Order("Juan");
        order.addItem(new OrderItem("Teclado", 2, new BigDecimal("19990.00")));
        order.addItem(new OrderItem("Mouse", 1, new BigDecimal("5000.50")));

        assertEquals(2, order.getItems().size());
        assertEquals(new BigDecimal("44980.50"), order.getTotalAmount());
    }

    @Test
    @DisplayName("canBeModified: solo un pedido PENDING es modificable")
    void shouldOnlyAllowModificationWhenPending() {
        Order order = new Order("Juan");
        assertTrue(order.canBeModified());

        for (OrderStatus status : new OrderStatus[]{
                OrderStatus.CONFIRMED, OrderStatus.SHIPPED, OrderStatus.DELIVERED, OrderStatus.CANCELLED}) {
            order.setStatus(status);
            assertFalse(order.canBeModified(), "No debería ser modificable en " + status);
        }
    }

    @Test
    @DisplayName("onCreate: asigna fecha de creación y valores por defecto")
    void shouldApplyDefaultsOnPersist() {
        Order order = new Order();
        order.onCreate();

        assertNotNull(order.getCreatedAt());
        assertEquals(OrderStatus.PENDING, order.getStatus());
        assertEquals(BigDecimal.ZERO, order.getTotalAmount());
    }

    @Test
    @DisplayName("equals: dos pedidos sin persistir no son iguales; con el mismo id sí")
    void shouldCompareByPersistentId() {
        Order a = new Order("A");
        Order b = new Order("B");
        assertNotEquals(a, b);
        assertEquals(a, a);

        a.setId(1L);
        b.setId(1L);
        assertEquals(a, b);
        assertEquals(a.hashCode(), b.hashCode());
    }
}
