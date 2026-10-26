package com.example.ordermanager.model;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;

import static org.junit.jupiter.api.Assertions.*;

@DisplayName("OrderItem - Pruebas unitarias del modelo")
class OrderItemTest {

    @Test
    @DisplayName("getSubtotal: cantidad x precio unitario")
    void shouldCalculateSubtotal() {
        OrderItem item = new OrderItem(" Monitor ", 3, new BigDecimal("150000.99"));

        assertEquals("Monitor", item.getProductName());
        assertEquals(new BigDecimal("450002.97"), item.getSubtotal());
    }

    @Test
    @DisplayName("constructor: rechaza producto vacío")
    void shouldRejectBlankProduct() {
        BigDecimal price = BigDecimal.TEN;
        assertThrows(IllegalArgumentException.class, () -> new OrderItem(null, 1, price));
        assertThrows(IllegalArgumentException.class, () -> new OrderItem(" ", 1, price));
    }

    @Test
    @DisplayName("constructor: rechaza cantidad cero o negativa")
    void shouldRejectNonPositiveQuantity() {
        BigDecimal price = BigDecimal.TEN;
        assertThrows(IllegalArgumentException.class, () -> new OrderItem("Mouse", 0, price));
        assertThrows(IllegalArgumentException.class, () -> new OrderItem("Mouse", -1, price));
    }

    @Test
    @DisplayName("constructor: rechaza precio nulo o negativo")
    void shouldRejectInvalidPrice() {
        BigDecimal negative = new BigDecimal("-1");
        assertThrows(IllegalArgumentException.class, () -> new OrderItem("Mouse", 1, null));
        assertThrows(IllegalArgumentException.class, () -> new OrderItem("Mouse", 1, negative));
    }

    @Test
    @DisplayName("equals: compara por valor")
    void shouldCompareByValue() {
        OrderItem a = new OrderItem("Mouse", 1, BigDecimal.TEN);
        OrderItem b = new OrderItem("Mouse", 1, BigDecimal.TEN);
        OrderItem c = new OrderItem("Mouse", 2, BigDecimal.TEN);

        assertEquals(a, b);
        assertEquals(a.hashCode(), b.hashCode());
        assertNotEquals(a, c);
        assertNotEquals(null, a);
    }
}
