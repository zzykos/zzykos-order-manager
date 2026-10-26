package com.example.ordermanager.service;

import com.example.ordermanager.dto.AddItemRequest;
import com.example.ordermanager.dto.CreateOrderRequest;
import com.example.ordermanager.exception.InvalidOrderStateException;
import com.example.ordermanager.exception.OrderNotFoundException;
import com.example.ordermanager.model.Order;
import com.example.ordermanager.model.OrderStatus;
import com.example.ordermanager.repository.OrderRepository;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
@DisplayName("OrderService - Pruebas unitarias")
class OrderServiceTest {

    @Mock
    private OrderRepository repository;

    @InjectMocks
    private OrderService service;

    @Test
    @DisplayName("getAllOrders: retorna lista completa")
    void shouldReturnAllOrders() {
        when(repository.findAll()).thenReturn(List.of(new Order("A"), new Order("B")));
        assertEquals(2, service.getAllOrders().size());
    }

    @Test
    @DisplayName("getOrderById: retorna pedido si existe")
    void shouldReturnOrderById() {
        Order order = new Order("Juan");
        order.setId(1L);
        when(repository.findById(1L)).thenReturn(Optional.of(order));

        Order result = service.getOrderById(1L);
        assertEquals("Juan", result.getCustomerName());
    }

    @Test
    @DisplayName("getOrderById: lanza excepción si no existe")
    void shouldThrowWhenOrderNotFound() {
        when(repository.findById(99L)).thenReturn(Optional.empty());
        assertThrows(OrderNotFoundException.class, () -> service.getOrderById(99L));
    }

    @Test
    @DisplayName("createOrder: crea pedido con ítems")
    void shouldCreateOrderWithItems() {
        when(repository.save(any(Order.class))).thenAnswer(i -> i.getArgument(0));

        CreateOrderRequest req = new CreateOrderRequest();
        req.setCustomerName("Juan");
        AddItemRequest item = new AddItemRequest("Laptop", 1, new BigDecimal("1200.00"));
        req.setItems(List.of(item));

        Order result = service.createOrder(req);

        assertEquals("Juan", result.getCustomerName());
        assertEquals(1, result.getItems().size());
        assertEquals(new BigDecimal("1200.00"), result.getTotalAmount());
        assertEquals(OrderStatus.PENDING, result.getStatus());
    }

    @Test
    @DisplayName("createOrder: crea pedido vacío")
    void shouldCreateEmptyOrder() {
        when(repository.save(any(Order.class))).thenAnswer(i -> i.getArgument(0));

        CreateOrderRequest req = new CreateOrderRequest();
        req.setCustomerName("Juan");

        Order result = service.createOrder(req);

        assertEquals(0, result.getItems().size());
        assertEquals(BigDecimal.ZERO, result.getTotalAmount());
    }

    @Test
    @DisplayName("addItem: agrega ítem a pedido PENDING")
    void shouldAddItemToPendingOrder() {
        Order order = new Order("Juan");
        order.setId(1L);
        when(repository.findById(1L)).thenReturn(Optional.of(order));
        when(repository.save(any(Order.class))).thenAnswer(i -> i.getArgument(0));

        AddItemRequest req = new AddItemRequest("Mouse", 2, new BigDecimal("25.50"));
        Order result = service.addItem(1L, req);

        assertEquals(1, result.getItems().size());
        assertEquals(new BigDecimal("51.00"), result.getTotalAmount());
    }

    @Test
    @DisplayName("addItem: falla si NO está PENDING")
    void shouldFailWhenAddingItemToConfirmedOrder() {
        Order order = new Order("Juan");
        order.setId(1L);
        order.setStatus(OrderStatus.CONFIRMED);
        when(repository.findById(1L)).thenReturn(Optional.of(order));

        AddItemRequest req = new AddItemRequest("Mouse", 1, new BigDecimal("25.00"));

        assertThrows(InvalidOrderStateException.class, () -> service.addItem(1L, req));
        verify(repository, never()).save(any(Order.class));
    }

    @Test
    @DisplayName("confirmOrder: PENDING → CONFIRMED")
    void shouldConfirmPendingOrder() {
        Order order = new Order("Juan");
        order.setId(1L);
        when(repository.findById(1L)).thenReturn(Optional.of(order));
        when(repository.save(any(Order.class))).thenAnswer(i -> i.getArgument(0));

        Order result = service.confirmOrder(1L);
        assertEquals(OrderStatus.CONFIRMED, result.getStatus());
    }

    @Test
    @DisplayName("confirmOrder: falla si no está PENDING")
    void shouldFailConfirmingShippedOrder() {
        Order order = new Order("Juan");
        order.setId(1L);
        order.setStatus(OrderStatus.SHIPPED);
        when(repository.findById(1L)).thenReturn(Optional.of(order));

        assertThrows(InvalidOrderStateException.class, () -> service.confirmOrder(1L));
    }

    @Test
    @DisplayName("shipOrder: CONFIRMED → SHIPPED")
    void shouldShipConfirmedOrder() {
        Order order = new Order("Juan");
        order.setId(1L);
        order.setStatus(OrderStatus.CONFIRMED);
        when(repository.findById(1L)).thenReturn(Optional.of(order));
        when(repository.save(any(Order.class))).thenAnswer(i -> i.getArgument(0));

        Order result = service.shipOrder(1L);
        assertEquals(OrderStatus.SHIPPED, result.getStatus());
    }

    @Test
    @DisplayName("deliverOrder: SHIPPED → DELIVERED")
    void shouldDeliverShippedOrder() {
        Order order = new Order("Juan");
        order.setId(1L);
        order.setStatus(OrderStatus.SHIPPED);
        when(repository.findById(1L)).thenReturn(Optional.of(order));
        when(repository.save(any(Order.class))).thenAnswer(i -> i.getArgument(0));

        Order result = service.deliverOrder(1L);
        assertEquals(OrderStatus.DELIVERED, result.getStatus());
    }

    @Test
    @DisplayName("cancelOrder: PENDING → CANCELLED")
    void shouldCancelPendingOrder() {
        Order order = new Order("Juan");
        order.setId(1L);
        when(repository.findById(1L)).thenReturn(Optional.of(order));
        when(repository.save(any(Order.class))).thenAnswer(i -> i.getArgument(0));

        Order result = service.cancelOrder(1L);
        assertEquals(OrderStatus.CANCELLED, result.getStatus());
    }

    @Test
    @DisplayName("cancelOrder: falla si ya está DELIVERED")
    void shouldFailCancellingDeliveredOrder() {
        Order order = new Order("Juan");
        order.setId(1L);
        order.setStatus(OrderStatus.DELIVERED);
        when(repository.findById(1L)).thenReturn(Optional.of(order));

        assertThrows(InvalidOrderStateException.class, () -> service.cancelOrder(1L));
    }

    @Test
    @DisplayName("cancelOrder: falla si ya está CANCELLED")
    void shouldFailCancellingCancelledOrder() {
        Order order = new Order("Juan");
        order.setId(1L);
        order.setStatus(OrderStatus.CANCELLED);
        when(repository.findById(1L)).thenReturn(Optional.of(order));

        assertThrows(InvalidOrderStateException.class, () -> service.cancelOrder(1L));
    }

    @Test
    @DisplayName("deleteOrder: elimina si existe")
    void shouldDeleteOrder() {
        when(repository.existsById(1L)).thenReturn(true);
        service.deleteOrder(1L);
        verify(repository).deleteById(1L);
    }

    @Test
    @DisplayName("deleteOrder: falla si no existe")
    void shouldFailDeletingNonExistent() {
        when(repository.existsById(99L)).thenReturn(false);
        assertThrows(OrderNotFoundException.class, () -> service.deleteOrder(99L));
        verify(repository, never()).deleteById(any());
    }

    @Test
    @DisplayName("getOrdersByStatus: delega el filtro al repositorio")
    void shouldReturnOrdersByStatus() {
        Order order = new Order("Juan");
        order.setStatus(OrderStatus.SHIPPED);
        when(repository.findByStatus(OrderStatus.SHIPPED)).thenReturn(List.of(order));

        List<Order> result = service.getOrdersByStatus(OrderStatus.SHIPPED);

        assertEquals(1, result.size());
        assertEquals(OrderStatus.SHIPPED, result.get(0).getStatus());
    }

    @Test
    @DisplayName("createOrder: falla con cliente vacío y no persiste")
    void shouldFailCreatingOrderWithBlankCustomer() {
        CreateOrderRequest req = new CreateOrderRequest();
        req.setCustomerName(" ");

        assertThrows(IllegalArgumentException.class, () -> service.createOrder(req));
        verify(repository, never()).save(any(Order.class));
    }

    @Test
    @DisplayName("addItem: falla si el pedido no existe")
    void shouldFailAddingItemToMissingOrder() {
        when(repository.findById(99L)).thenReturn(Optional.empty());
        AddItemRequest req = new AddItemRequest("Mouse", 1, BigDecimal.TEN);

        assertThrows(OrderNotFoundException.class, () -> service.addItem(99L, req));
        verify(repository, never()).save(any(Order.class));
    }

    @Test
    @DisplayName("shipOrder: falla si no está CONFIRMED")
    void shouldFailShippingPendingOrder() {
        Order order = new Order("Juan");
        order.setId(1L);
        when(repository.findById(1L)).thenReturn(Optional.of(order));

        assertThrows(InvalidOrderStateException.class, () -> service.shipOrder(1L));
        verify(repository, never()).save(any(Order.class));
    }

    @Test
    @DisplayName("deliverOrder: falla si no está SHIPPED")
    void shouldFailDeliveringConfirmedOrder() {
        Order order = new Order("Juan");
        order.setId(1L);
        order.setStatus(OrderStatus.CONFIRMED);
        when(repository.findById(1L)).thenReturn(Optional.of(order));

        assertThrows(InvalidOrderStateException.class, () -> service.deliverOrder(1L));
        verify(repository, never()).save(any(Order.class));
    }

    @Test
    @DisplayName("cancelOrder: SHIPPED → CANCELLED")
    void shouldCancelShippedOrder() {
        Order order = new Order("Juan");
        order.setId(1L);
        order.setStatus(OrderStatus.SHIPPED);
        when(repository.findById(1L)).thenReturn(Optional.of(order));
        when(repository.save(any(Order.class))).thenAnswer(i -> i.getArgument(0));

        assertEquals(OrderStatus.CANCELLED, service.cancelOrder(1L).getStatus());
    }
}
